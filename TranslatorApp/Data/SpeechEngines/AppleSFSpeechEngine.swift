//
//  AppleSFSpeechEngine.swift
//  TranslatorApp
//
//  The single speech-recognition engine (008-fix-audio-pipeline-resilience).
//
//  CONSOLIDATES three files that implemented the same rotation logic twice and had already
//  diverged: ContinuousSpeechListener, LegacySFSpeechEngine and AppleSpeechAnalyzerEngine.
//  Only one of them had a watchdog; only the other closed the stream when a restart failed, so
//  a failed restart on the second left the pipeline dead with the UI still showing "recording".
//  Both behaviours are kept here, once.
//
//  (AppleSpeechAnalyzerEngine was also misnamed: despite the name it used SFSpeechRecognizer,
//  not iOS 26's SpeechAnalyzer. Migrating to SpeechAnalyzer is deliberately out of scope for
//  this phase — see research.md §R6.)
//
//  ROTATION IS A POINTER SWAP. The tap is owned by AudioCaptureSession and installed once per
//  recording session. Rotating means swapping the request inside RecognitionRequestBox, so
//  there is no window in which nothing is capturing (research §R4).
//
//  Stopping lives in AppleSFSpeechEngine+Shutdown.swift; request and replay policy in
//  AppleSFSpeechEngine+Policy.swift.
//

import Speech
import AVFoundation
import OSLog

actor AppleSFSpeechEngine: SpeechEngineProtocol {

    nonisolated let engineId: EngineId = .legacyAppleSFSpeech

    let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "AppleSFSpeech")
    let telemetry: any PipelineTelemetryProtocol
    let capture: AudioCaptureSession
    let requestBox: RecognitionRequestBox
    let ringBuffer: AudioRingBuffer
    let sessionCoordinator: any AudioSessionCoordinatorProtocol
    /// Read to tell a pause apart from a recogniser that has stopped listening. Without it,
    /// "no transcript for four seconds" is ambiguous and cannot be acted on.
    let levelMonitor: AudioLevelMonitor

    private var recognizer: SFSpeechRecognizer?
    var recognitionTask: SFSpeechRecognitionTask?
    var continuation: AsyncStream<SpeechSegment>.Continuation?

    var isFinished = false
    var isRotating = false
    /// Set while `stop()` lets the recogniser deliver what it already heard. Rotation is off in
    /// this state: the session is ending, not recovering.
    var isStopping = false
    /// The final result — or the error — that closes the last request arrived during `stop()`.
    var stopFinalReceived = false
    /// Bumped by EVERY `stop()`. `start()` suspends several times, and a stop can land in any of
    /// those gaps; `start()` compares this before going live and abandons instead of resetting
    /// the flags the stop just set (field log 2026-09-15).
    var lifecycleEpoch = 0
    /// Identifies the recording session a recogniser callback belongs to. `generation` restarts
    /// at 0 every session, so it alone cannot reject a callback from a previous one.
    var sessionOrdinal = 0
    var restartCount = 0
    var generation = 0
    var sessionId = "----"
    var sessionStartedAt = MonotonicClock.now()
    var lastTranscriptAt = MonotonicClock.now()
    var watchdogTask: Task<Void, Never>?
    var deafTask: Task<Void, Never>?
    var consecutiveDeafRotations = 0
    var resilienceTask: Task<Void, Never>?
    var isSuspended = false

    /// Fires this long after the last sign of life. A healthy session refreshes it on every
    /// transcript update, so it only trips when the pipeline has actually gone quiet.
    let watchdogTimeoutNs: UInt64 = 65_000_000_000

    /// How long the recogniser may produce nothing while the microphone is carrying speech.
    ///
    /// Sixty-five seconds is the right timeout for "the session died"; it is far too long for
    /// "a new speaker started and the recogniser did not follow". Field logs showed fourteen
    /// consecutive seconds of speech-level audio with not one partial result, no final, no
    /// error and no rotation — the recogniser was simply not listening any more, and nothing in
    /// the app was in a position to notice.
    nonisolated static var deafTimeoutMs: Int { 4_000 }
    /// Backs off when rotating does not bring it back — at that point the problem is not the
    /// recogniser and re-creating it every four seconds is just noise. Reset by any transcript.
    nonisolated static var deafBackoffCeilingMs: Int { 16_000 }

    init(telemetry: any PipelineTelemetryProtocol,
         capture: AudioCaptureSession,
         requestBox: RecognitionRequestBox,
         ringBuffer: AudioRingBuffer,
         sessionCoordinator: any AudioSessionCoordinatorProtocol,
         levelMonitor: AudioLevelMonitor) {
        self.telemetry = telemetry
        self.capture = capture
        self.requestBox = requestBox
        self.ringBuffer = ringBuffer
        self.sessionCoordinator = sessionCoordinator
        self.levelMonitor = levelMonitor
    }

    // MARK: - SpeechEngineProtocol

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        // A stop can arrive while this is suspended. It used to set its flags, then this method
        // resumed, reset them and went live — the microphone kept capturing after the user had
        // pressed stop, and the next meeting replayed that audio (field log 2026-09-15).
        let epoch = lifecycleEpoch
        guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
            throw SpeechEngineError.notAuthorized
        }
        guard epoch == lifecycleEpoch else { throw CancellationError() }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: options.locale)) else {
            throw SpeechEngineError.unsupportedLocale
        }
        // Checked before anything is captured. Without local support the request used to go to
        // Apple's servers; now recording simply does not start.
        try Self.verifyOnDeviceRecognition(supported: recognizer.supportsOnDeviceRecognition)
        self.recognizer = recognizer

        sessionOrdinal += 1
        sessionId = TelemetrySessionId.new()
        isFinished = false
        isRotating = false
        isStopping = false
        stopFinalReceived = false
        isSuspended = false
        restartCount = 0
        generation = 0
        sessionStartedAt = MonotonicClock.now()
        lastTranscriptAt = sessionStartedAt

        // Assigned synchronously so early recogniser callbacks are never dropped.
        let stream = AsyncStream<SpeechSegment> { continuation in
            self.continuation = continuation
        }

        await sessionCoordinator.setSessionId(sessionId)
        await sessionCoordinator.startObserving()
        try await sessionCoordinator.activate()
        try await capture.start(sessionId: sessionId)
        guard epoch == lifecycleEpoch else {
            await abandonStart()
            throw CancellationError()
        }

        telemetry.sessionStart(sessionId,
                               engineId: engineId.rawValue,
                               locale: options.locale,
                               onDevice: true)
        startResilienceLoop()
        try startRecognitionTask(trigger: .manual)
        return stream
    }

    // MARK: - Recognition task

    /// Builds a fresh request, makes it the active one, and starts its task.
    /// Never touches the microphone tap.
    @discardableResult
    func startRecognitionTask(trigger: RestartTrigger) throws -> CarryOver {
        guard let recognizer else { throw SpeechEngineError.engineConfigurationFailed }

        // Context, not volume. A quiet speaker is missed because the model has too little
        // evidence to commit to a word — not because the signal is small. Telling it which words
        // to expect lowers the evidence it needs.
        let request = Self.makeRequest(vocabulary: ContextualVocabulary.terms)
        if !request.contextualStrings.isEmpty {
            logger.info("[AppleSFSpeech] biasing \(request.contextualStrings.count) contextual term(s)")
        }

        // Replay recent audio into the new request and make it the active one in a single step
        // under the tap's lock, so no buffer can fall between the two (research 2026-09-15, A5).
        let replayMs = Self.replayWindowMs(trigger: trigger,
                                           msSinceLastTranscript: MonotonicClock.msSince(lastTranscriptAt))
        let swap = requestBox.swap(to: request, replaying: ringBuffer, lastMs: replayMs)
        let carryOver = CarryOver(buffers: swap.replayedBuffers, ms: swap.replayedMs)
        let currentGeneration = generation
        let ordinal = sessionOrdinal

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self else { return }
            let isFinal = result?.isFinal ?? false
            let text = result?.bestTranscription.formattedString ?? ""
            let segments = result?.bestTranscription.segments ?? []
            let tokens = segments.map { segment in
                TranscriptToken(text: segment.substring,
                                confidence: max(0, min(1, segment.confidence)),
                                startTime: segment.timestamp,
                                endTime: segment.timestamp + segment.duration)
            }
            let nsError = error as NSError?
            Task { [weak self] in
                await self?.handleResult(request: request,
                                         text: text,
                                         isFinal: isFinal,
                                         tokens: tokens,
                                         generation: currentGeneration,
                                         ordinal: ordinal,
                                         errorDomain: nsError?.domain,
                                         errorCode: nsError?.code)
            }
        }

        // Tear the previous layer down only now, once the new one is already live.
        swap.previous?.endAudio()
        telemetry.tapSwap(sessionId,
                          restartIndex: restartCount,
                          blindWindowMs: 0,   // structural: the tap was never removed
                          carryOverBuffers: carryOver.buffers)
        armWatchdog()
        armDeafWatchdog()
        logger.info("[AppleSFSpeech] recognition task started gen=\(currentGeneration) trigger=\(trigger.rawValue, privacy: .public) replayMs=\(carryOver.ms)")
        return carryOver
    }
}
