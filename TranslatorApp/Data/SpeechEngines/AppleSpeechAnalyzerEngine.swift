//
//  AppleSpeechAnalyzerEngine.swift
//  TranslatorApp
//
//  iOS 26 SpeechAnalyzer + SpeechTranscriber (migration, 2026-09-15).
//
//  WHY
//  Apple built SpeechTranscriber for long-form and distant audio — meetings — and it runs its model
//  outside the app's memory. Above all, it does not throw its transcript away at every change of
//  speaker, which SFSpeechRecognizer does without telling anyone: every "first words lost" defect
//  so far came from reconstructing text around those silent restarts.
//
//  WHAT STAYS THE SAME
//  The same permanent microphone tap (`AudioCaptureSession`), the same audio session owner and its
//  interruption handling, and the same `SpeechSegment` stream: the segmenter, translation, journal
//  and interface do not know which engine is running. On-device only: SpeechTranscriber never
//  sends audio anywhere; its model is DOWNLOADED to the device through `AssetInventory`.
//
//  If anything here fails to start, `SelectingSpeechEngine` falls back to `AppleSFSpeechEngine`.
//

import AVFoundation
import OSLog
import Speech

actor AppleSpeechAnalyzerEngine: SpeechEngineProtocol {

    nonisolated let engineId: EngineId = .appleSpeechAnalyzer

    let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "SpeechAnalyzer")
    let telemetry: any PipelineTelemetryProtocol
    let capture: AudioCaptureSession
    let sessionCoordinator: any AudioSessionCoordinatorProtocol
    let audioSink: AudioBufferSink
    /// Read by the finalisation pacer to find the speaker's pauses.
    let levelMonitor: AudioLevelMonitor
    /// One for the engine's whole life: a stop never deallocates audio conversion.
    let converter = AnalyzerAudioConverter()

    var analyzer: SpeechAnalyzer?
    var pacer = FinalizationPacer()
    var pacerTask: Task<Void, Never>?
    var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    var resultsTask: Task<Void, Never>?
    var continuation: AsyncStream<SpeechSegment>.Continuation?
    var resilienceTask: Task<Void, Never>?
    var transcript = AnalyzerTranscriptAccumulator()

    var isFinished = false
    var isStopping = false
    var isSuspended = false
    /// Bumped by every `stop()`, so a stop that lands while `start()` is suspended wins.
    var lifecycleEpoch = 0
    /// Identifies the recording session results belong to.
    var sessionOrdinal = 0
    var sessionId = "----"
    var sessionStartedAt = MonotonicClock.now()

    nonisolated static var isSupportedOnThisDevice: Bool { SpeechTranscriber.isAvailable }

    init(telemetry: any PipelineTelemetryProtocol,
         capture: AudioCaptureSession,
         sessionCoordinator: any AudioSessionCoordinatorProtocol,
         audioSink: AudioBufferSink,
         levelMonitor: AudioLevelMonitor) {
        self.telemetry = telemetry
        self.capture = capture
        self.sessionCoordinator = sessionCoordinator
        self.audioSink = audioSink
        self.levelMonitor = levelMonitor
    }

    // MARK: - SpeechEngineProtocol

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        let epoch = lifecycleEpoch
        guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
            throw SpeechEngineError.notAuthorized
        }
        guard Self.isSupportedOnThisDevice else { throw SpeechEngineError.unsupportedDevice }
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: options.locale)) else {
            throw SpeechEngineError.unsupportedLocale
        }

        let transcriber = SpeechTranscriber(locale: locale,
                                            transcriptionOptions: [],
                                            reportingOptions: [.volatileResults],
                                            attributeOptions: [])
        try await installModelIfNeeded(for: transcriber)
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw SpeechEngineError.engineConfigurationFailed
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        try await analyzer.prepareToAnalyze(in: format)
        guard epoch == lifecycleEpoch else { throw CancellationError() }

        sessionOrdinal += 1
        sessionId = TelemetrySessionId.new()
        isFinished = false
        isStopping = false
        isSuspended = false
        sessionStartedAt = MonotonicClock.now()
        transcript = AnalyzerTranscriptAccumulator()
        pacer = FinalizationPacer()
        self.analyzer = analyzer

        let (inputStream, inputContinuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        self.inputContinuation = inputContinuation
        converter.configure(targetFormat: format, continuation: inputContinuation)
        let (output, outputContinuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        continuation = outputContinuation

        await sessionCoordinator.setSessionId(sessionId)
        await sessionCoordinator.startObserving()
        try await sessionCoordinator.activate()
        audioSink.add(converter)
        try await capture.start(sessionId: sessionId)
        guard epoch == lifecycleEpoch else {
            await abandonStart()
            throw CancellationError()
        }

        try await analyzer.start(inputSequence: inputStream)
        startConsumingResults(of: transcriber)
        startResilienceLoop()
        startFinalizationPacer()
        telemetry.sessionStart(sessionId, engineId: engineId.rawValue, locale: locale.identifier, onDevice: true)
        logger.info("[SpeechAnalyzer] started fmt=\(Int(format.sampleRate))Hz/\(format.channelCount)ch")
        return output
    }

    // MARK: - Model

    /// Downloads the transcription model to the device if it is not there yet. The only network
    /// traffic this engine causes, and it goes in the permitted direction: to the device.
    private func installModelIfNeeded(for transcriber: SpeechTranscriber) async throws {
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) else {
            return
        }
        telemetry.speechModel(sessionId, state: "downloading")
        do {
            try await request.downloadAndInstall()
            telemetry.speechModel(sessionId, state: "installed")
        } catch {
            telemetry.speechModel(sessionId, state: "failed")
            throw SpeechEngineError.modelUnavailable
        }
    }

    // MARK: - Results

    private func startConsumingResults(of transcriber: SpeechTranscriber) {
        let ordinal = sessionOrdinal
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    await self?.handleResult(text: String(result.text.characters),
                                             isFinal: result.isFinal,
                                             ordinal: ordinal)
                }
                await self?.resultsDidEnd(error: nil, ordinal: ordinal)
            } catch {
                await self?.resultsDidEnd(error: error, ordinal: ordinal)
            }
        }
    }

    private func handleResult(text: String, isFinal: Bool, ordinal: Int) {
        guard ordinal == sessionOrdinal, !isFinished else { return }
        let update = transcript.apply(text: text, isFinal: isFinal)
        if update.didFinalize { pacer.finalReceived() }

        // Phrases are built from FINALISED text only (first field test, 2026-09-15). Fed the
        // volatile guesses, the segmenter committed words the recogniser rewrote a moment later,
        // read every rewrite as a revision — revRate 48.8, "low quality", 1.2–2.5 s delays — and
        // cut one-word fragments at the ceiling while the guess was still moving.
        if update.didFinalize, !update.finalizedText.isEmpty {
            continuation?.yield(SpeechSegment(text: update.finalizedText,
                                              isFinal: false,
                                              confidence: 0.9,
                                              source: engineId,
                                              sessionGeneration: update.generation))
        }
        // Everything, volatile included, for the live pane and the on-disk draft only. A
        // hypothesis never reaches the segmenter (TranscribeAudioUseCase).
        guard !update.text.isEmpty else { return }
        continuation?.yield(SpeechSegment(text: update.text,
                                          isFinal: false,
                                          confidence: 0.9,
                                          source: engineId,
                                          isHypothesis: true,
                                          sessionGeneration: update.generation))
    }

    private func resultsDidEnd(error: Error?, ordinal: Int) {
        guard ordinal == sessionOrdinal, !isStopping, !isFinished else { return }
        let nsError = error as NSError?
        telemetry.sessionEnd(sessionId,
                             reason: .error,
                             errorDomain: nsError?.domain ?? "SpeechAnalyzer",
                             errorCode: nsError?.code ?? -1,
                             durationMs: MonotonicClock.msSince(sessionStartedAt),
                             restartIndex: 0)
        logger.error("[SpeechAnalyzer] results ended unexpectedly: \(nsError?.domain ?? "-", privacy: .public)/\(nsError?.code ?? -1)")
        // Ends the stream: the session stops and the meeting so far is kept and offered to the user.
        isFinished = true
        continuation?.finish()
        continuation = nil
    }
}
