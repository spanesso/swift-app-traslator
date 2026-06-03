//
//  WhisperModelManager.swift
//  TranslatorApp
//

import Foundation
import OSLog
import WhisperKit

// MARK: - Error types (Data layer only — never imported by Domain)

enum WhisperASRError: Error, LocalizedError {
    case unsupportedHardware
    case downloadFailed(Error)
    case modelLoadFailed(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedHardware:
            return "On-device speech recognition requires Apple Silicon. Your Mac will use system speech recognition instead."
        case .downloadFailed(let e):
            return "Model download failed: \(e.localizedDescription). Check your internet connection and try again."
        case .modelLoadFailed(let e):
            return "Could not load the speech model: \(e.localizedDescription)"
        }
    }
}

// MARK: - WhisperModelManager

actor WhisperModelManager {

    // MARK: - Public

    /// Real-time download progress (0.0–1.0). Emits only during an active download.
    nonisolated let downloadProgress: AsyncStream<Double>

    // MARK: - Private

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "WhisperASR")
    private let modelVariant: String

    private var progressContinuation: AsyncStream<Double>.Continuation?

    // WhisperKit is open class (non-Sendable). Keep it actor-isolated — never return it
    // across actor boundaries. AudioStreamTranscriber (actor, Sendable) is returned instead.
    private var loadedKit: WhisperKit?
    private var isLoading = false
    private var waiters: [CheckedContinuation<Void, Error>] = []

    // MARK: - Init

    init(modelVariant: String = "openai_whisper-large-v3_turbo") {
        self.modelVariant = modelVariant
        var capture: AsyncStream<Double>.Continuation?
        downloadProgress = AsyncStream<Double>(bufferingPolicy: .bufferingNewest(1)) { capture = $0 }
        progressContinuation = capture
    }

    // MARK: - Public API

    /// Creates a fully configured AudioStreamTranscriber backed by the loaded WhisperKit model.
    /// Downloads and initialises the model on first call; subsequent calls reuse the cached instance.
    /// WhisperKit never leaves this actor — AudioStreamTranscriber (actor, Sendable) crosses the boundary.
    func makeTranscriber(
        decodingOptions: DecodingOptions,
        stateChangeCallback: AudioStreamTranscriberCallback?
    ) async throws -> AudioStreamTranscriber {
        try await ensureLoaded()

        guard let kit = loadedKit, let tokenizer = kit.tokenizer else {
            throw WhisperASRError.modelLoadFailed(CocoaError(.featureUnsupported))
        }

        return AudioStreamTranscriber(
            audioEncoder: kit.audioEncoder,
            featureExtractor: kit.featureExtractor,
            segmentSeeker: kit.segmentSeeker,
            textDecoder: kit.textDecoder,
            tokenizer: tokenizer,
            audioProcessor: AudioProcessor(),
            decodingOptions: decodingOptions,
            stateChangeCallback: stateChangeCallback
        )
    }

    /// Cancels any in-flight download or load and resumes all waiters with CancellationError.
    func cancelLoading() {
        guard isLoading else { return }
        isLoading = false
        loadedKit = nil
        let pending = waiters
        waiters = []
        for c in pending { c.resume(throwing: CancellationError()) }
        logger.info("[WhisperASR] Loading cancelled")
    }

    // MARK: - Private

    private func ensureLoaded() async throws {
        if loadedKit != nil { return }

        if isLoading {
            // Join the queue — suspended until the in-progress load finishes or fails.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                waiters.append(continuation)
            }
            return
        }

        isLoading = true

        do {
            guard Self.isAppleSilicon() else {
                isLoading = false
                logger.warning("[WhisperASR] Intel Mac detected — WhisperKit not supported")
                throw WhisperASRError.unsupportedHardware
            }

            logger.info("[WhisperASR] Starting model load for variant: \(self.modelVariant)")

            let modelFolderURL = try await WhisperKit.download(
                variant: modelVariant,
                progressCallback: { [weak self] progress in
                    guard let self else { return }
                    // Capture the Double value, not the Progress object, to avoid
                    // sending a non-Sendable Foundation.Progress across the Task boundary.
                    let fraction = progress.fractionCompleted
                    Task { await self.yieldProgress(fraction) }
                }
            )

            // Download complete — hide the progress overlay immediately.
            // The subsequent WhisperKit(config) init takes several seconds loading CoreML
            // models into memory; that phase runs silently with no overlay.
            progressContinuation?.yield(1.0)

            // Pass the downloaded folder explicitly so WhisperKit loads models into memory.
            // Without modelFolder, WhisperKitConfig.load defaults to nil → false (models skipped).
            let config = WhisperKitConfig(
                model: modelVariant,
                modelFolder: modelFolderURL.path,
                load: true,
                download: false
            )
            loadedKit = try await WhisperKit(config)
            isLoading = false
            logger.info("[WhisperASR] Model loaded successfully")

            let pending = waiters
            waiters = []
            for c in pending { c.resume() }

        } catch {
            isLoading = false
            logger.error("[WhisperASR] Load failed: \(error)")
            let pending = waiters
            waiters = []
            for c in pending { c.resume(throwing: error) }
            throw error
        }
    }

    private func yieldProgress(_ fraction: Double) {
        progressContinuation?.yield(max(0.0, min(1.0, fraction)))
    }

    private static func isAppleSilicon() -> Bool {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }
}
