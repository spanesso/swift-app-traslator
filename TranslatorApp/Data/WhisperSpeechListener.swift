//
//  WhisperSpeechListener.swift
//  TranslatorApp
//

import Foundation
import OSLog
import WhisperKit

actor WhisperSpeechListener {

    // MARK: - Private state

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "WhisperASR")
    private let modelManager: WhisperModelManager

    private var continuation: AsyncStream<SpeechSegment>.Continuation?
    private var transcriber: AudioStreamTranscriber?
    // startStreamTranscription() runs a blocking realtime loop. Fired in a Task so start() returns.
    private var transcriptionLoopTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var isFinished = false

    // MARK: - Init

    init(modelManager: WhisperModelManager) {
        self.modelManager = modelManager
    }

    // MARK: - Public API

    func start() async throws -> AsyncStream<SpeechSegment> {
        isFinished = false
        let stream = AsyncStream<SpeechSegment>(bufferingPolicy: .bufferingNewest(8)) { continuation in
            self.continuation = continuation
        }

        let newTranscriber = try await modelManager.makeTranscriber(
            decodingOptions: Self.makeDecodingOptions(),
            stateChangeCallback: { [weak self] oldState, newState in
                guard let self else { return }
                Task { await self.handleStateChange(oldState: oldState, newState: newState) }
            }
        )

        transcriber = newTranscriber
        launchTranscriptionLoop(newTranscriber)
        scheduleWatchdog()
        logger.info("[WhisperASR] Transcription started")
        return stream
    }

    func stop() async {
        logger.info("[WhisperASR] Stopping transcription")
        watchdogTask?.cancel()
        watchdogTask = nil
        isFinished = true
        // stopStreamTranscription sets isRecording = false → realtimeLoop exits → loop Task finishes.
        await transcriber?.stopStreamTranscription()
        transcriptionLoopTask?.cancel()
        transcriptionLoopTask = nil
        transcriber = nil
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Transcription loop

    private func launchTranscriptionLoop(_ t: AudioStreamTranscriber) {
        transcriptionLoopTask?.cancel()
        transcriptionLoopTask = Task { [weak self] in
            do {
                try await t.startStreamTranscription()
            } catch {
                await self?.handleTranscriptionLoopError(error)
                return
            }
            // startStreamTranscription() returned without throwing.
            // Expected when stop() was called (isFinished = true).
            // Unexpected if isFinished = false: mic denied or internal WhisperKit loop break.
            await self?.handleUnexpectedLoopExit()
        }
    }

    private func handleTranscriptionLoopError(_ error: Error) {
        guard !isFinished else { return }
        logger.error("[WhisperASR] Transcription loop failed: \(error)")
        isFinished = true
        continuation?.finish()
        continuation = nil
    }

    private func handleUnexpectedLoopExit() {
        guard !isFinished else { return }
        // Likely causes: mic permission denied (AudioProcessor.requestRecordPermission returns false)
        // or an internal WhisperKit inference error that breaks the realtimeLoop silently.
        logger.error("[WhisperASR] Transcription loop exited unexpectedly — check mic permission and model state")
        isFinished = true
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Segment handling

    private func handleStateChange(
        oldState: AudioStreamTranscriber.State,
        newState: AudioStreamTranscriber.State
    ) {
        guard !isFinished else { return }
        scheduleWatchdog()

        let prevConfirmedCount = oldState.confirmedSegments.count
        let confirmedSegments = newState.confirmedSegments
        if confirmedSegments.count > prevConfirmedCount {
            for seg in confirmedSegments[prevConfirmedCount...] {
                let confidence = confidenceFrom(seg)
                let segment = SpeechSegment(text: seg.text, isFinal: true, confidence: confidence)
                continuation?.yield(segment)
                logger.debug("[WhisperASR] confirmed: '\(seg.text.prefix(60))' conf=\(String(format: "%.2f", confidence))")
            }
        }

        if let latest = newState.unconfirmedSegments.last {
            let partial = SpeechSegment(text: latest.text, isFinal: false, confidence: 0.5)
            continuation?.yield(partial)
        }
    }

    private func confidenceFrom(_ segment: TranscriptionSegment) -> Float {
        return max(0.0, min(1.0, exp(segment.avgLogprob)))
    }

    // MARK: - Watchdog

    private func scheduleWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000) // 30 s
            guard !Task.isCancelled else { return }
            await self?.restartAudioPipeline()
        }
    }

    private func restartAudioPipeline() async {
        guard !isFinished else { return }
        logger.warning("[WhisperASR] Watchdog triggered — restarting audio pipeline")

        await transcriber?.stopStreamTranscription()
        transcriptionLoopTask?.cancel()
        transcriptionLoopTask = nil
        try? await Task.sleep(nanoseconds: 200_000_000)

        guard !isFinished, let t = transcriber else { return }
        launchTranscriptionLoop(t)
        scheduleWatchdog()
        logger.info("[WhisperASR] Audio pipeline restarted")
    }

    // MARK: - Configuration

    private static func makeDecodingOptions() -> DecodingOptions {
        // chunkingStrategy and wordTimestamps are for batch transcription.
        // In streaming mode AudioStreamTranscriber handles VAD and chunking internally.
        var options = DecodingOptions()
        options.task = .transcribe
        options.language = "en"
        options.usePrefillPrompt = true
        options.skipSpecialTokens = true
        options.noSpeechThreshold = 0.6
        options.temperature = 0.0
        return options
    }
}
