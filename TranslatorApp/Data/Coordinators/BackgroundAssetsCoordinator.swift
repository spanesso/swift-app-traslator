//
//  BackgroundAssetsCoordinator.swift
//  TranslatorApp
//
//  Manages the WhisperKit model download lifecycle using URLSession background tasks.
//  State machine follows the legal transitions defined in data-model.md §1.6.
//  Production builds may upgrade the URLSession impl to BADownloadManager (BackgroundAssets)
//  for true background download continuity when the app is suspended.

import Foundation
import OSLog

actor BackgroundAssetsCoordinator: ModelDownloadCoordinatorProtocol {
    nonisolated static var modelIdentifier: String { "whisperkit-large-v3-turbo" }
    nonisolated static var installedKey: String { "whsk.installed" }
    // Model hosted on Hugging Face via the WhisperKit project
    nonisolated static var modelURL: URL { URL(string:
        "https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/openai_whisper-large-v3-turbo.mlpackage.zip"
    )! }
    nonisolated static var expectedSizeBytes: Int64 { 620_000_000 } // ~600 MB compressed

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Coordinator")
    private var _state: ModelInstallState = .notRequested
    private var streamContinuations: [UUID: AsyncStream<ModelInstallState>.Continuation] = [:]
    private var downloadTask: URLSessionDownloadTask?
    private var observation: NSKeyValueObservation?

    var currentState: ModelInstallState { _state }

    func stateStream() -> AsyncStream<ModelInstallState> {
        let currentValue = _state
        let id = UUID()
        return AsyncStream { [self] cont in
            cont.yield(currentValue)
            self.streamContinuations[id] = cont
            cont.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id: id) }
            }
        }
    }

    /// 008 (US4 / FR-020): the local engine is withdrawn in this build, so the app must not
    /// offer or start a ~600 MB download for something it will not use. Already-downloaded
    /// models are left on disk untouched.
    nonisolated static var isModelDownloadEnabled: Bool { EnginePreference.whisperPreferred.isAvailable }

    func acceptDownload() async {
        guard Self.isModelDownloadEnabled else {
            logger.notice("[Coordinator] download suppressed: the local engine is withdrawn in this build")
            return
        }
        guard case .awaitingConsent = _state else {
            let stateDesc = _state.description
            logger.warning("[Coordinator] acceptDownload called in invalid state: \(stateDesc, privacy: .public)")
            return
        }
        await transitionTo(.downloading(progress: 0.0))
        startURLSessionDownload()
    }

    func declineDownload() async {
        guard case .awaitingConsent = _state else { return }
        await transitionTo(.declined)
    }

    func retryRequest() async {
        switch _state {
        case .declined, .failed: await transitionTo(.awaitingConsent)
        default: break
        }
    }

    func requestConsentIfNeeded() async {
        guard Self.isModelDownloadEnabled else { return }
        if case .notRequested = _state {
            await transitionTo(.awaitingConsent)
        }
    }

    func _forceState(_ state: ModelInstallState) async {
        await transitionTo(state)
    }

    // MARK: - Private

    private func startURLSessionDownload() {
        let config = URLSessionConfiguration.background(withIdentifier:
            "com.spanesso.TranslatorApp.whisperkit-download")
        config.isDiscretionary = false
        config.allowsCellularAccess = false // Wi-Fi only
        let session = URLSession(configuration: config,
                                 delegate: DownloadDelegate(coordinator: self),
                                 delegateQueue: nil)
        downloadTask = session.downloadTask(with: Self.modelURL)
        observation = downloadTask?.progress.observe(\.fractionCompleted) { [weak self] progress, _ in
            Task { await self?.transitionTo(.downloading(progress: progress.fractionCompleted)) }
        }
        downloadTask?.resume()
        logger.info("[Coordinator] URLSession download started")
    }

    func handleDownloadCompletion(at location: URL) async {
        do {
            let dest = try modelDestinationURL()
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            UserDefaults.standard.set(true, forKey: Self.installedKey)
            await transitionTo(.installed(version: "large-v3-turbo", sizeBytes: Self.expectedSizeBytes))
            logger.info("[Coordinator] model installed at \(dest.path)")
        } catch {
            await transitionTo(.failed(reason: .unknown))
            logger.error("[Coordinator] install failed: \(error)")
        }
    }

    func handleDownloadError(_ error: Error) async {
        let reason: ModelInstallFailure = (error as NSError).code == NSURLErrorNotConnectedToInternet
            ? .networkUnavailable : .unknown
        await transitionTo(.failed(reason: reason))
    }

    private func modelDestinationURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = support.appendingPathComponent("WhisperKit/large-v3-turbo-compressed", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("model.zip")
    }

    private func transitionTo(_ newState: ModelInstallState) async {
        let oldDesc = _state.description
        let newDesc = newState.description
        logger.info("[Coordinator] \(oldDesc, privacy: .public) → \(newDesc, privacy: .public)")
        _state = newState
        for cont in streamContinuations.values { cont.yield(newState) }
    }

    private func removeContinuation(id: UUID) {
        streamContinuations.removeValue(forKey: id)
    }
}

// MARK: - URLSession delegate (inner class, not an actor)

private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, Sendable {
    private let coordinator: BackgroundAssetsCoordinator
    init(coordinator: BackgroundAssetsCoordinator) { self.coordinator = coordinator }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        Task { await coordinator.handleDownloadCompletion(at: location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { Task { await coordinator.handleDownloadError(error) } }
    }
}
