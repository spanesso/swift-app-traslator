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

    private var recognizer: SFSpeechRecognizer?
    var recognitionTask: SFSpeechRecognitionTask?
    var continuation: AsyncStream<SpeechSegment>.Continuation?

    var isFinished = false
    var isRotating = false
    var restartCount = 0
    var generation = 0
    var sessionId = "----"
    var sessionStartedAt = MonotonicClock.now()
    var lastTranscriptAt = MonotonicClock.now()
    var watchdogTask: Task<Void, Never>?
    var resilienceTask: Task<Void, Never>?
    var isSuspended = false

    /// Fires this long after the last sign of life. A healthy session refreshes it on every
    /// transcript update, so it only trips when the pipeline has actually gone quiet.
    let watchdogTimeoutNs: UInt64 = 65_000_000_000

    init(telemetry: any PipelineTelemetryProtocol,
         capture: AudioCaptureSession,
         requestBox: RecognitionRequestBox,
         ringBuffer: AudioRingBuffer,
         sessionCoordinator: any AudioSessionCoordinatorProtocol) {
        self.telemetry = telemetry
        self.capture = capture
        self.requestBox = requestBox
        self.ringBuffer = ringBuffer
        self.sessionCoordinator = sessionCoordinator
    }

    // MARK: - SpeechEngineProtocol

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
            throw SpeechEngineError.notAuthorized
        }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: options.locale)) else {
            throw SpeechEngineError.unsupportedLocale
        }
        self.recognizer = recognizer

        sessionId = TelemetrySessionId.new()
        isFinished = false
        isRotating = false
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

        telemetry.sessionStart(sessionId,
                               engineId: engineId.rawValue,
                               locale: options.locale,
                               onDevice: Self.prefersOnDevice(recognizer))
        startResilienceLoop()
        try startRecognitionTask(trigger: .manual)
        return stream
    }

    func stop() async {
        logger.info("[AppleSFSpeech] stop (rotations=\(self.restartCount))")
        telemetry.sessionEnd(sessionId,
                             reason: .userStop,
                             errorDomain: nil,
                             errorCode: nil,
                             durationMs: MonotonicClock.msSince(sessionStartedAt),
                             restartIndex: restartCount)
        isFinished = true
        watchdogTask?.cancel(); watchdogTask = nil
        resilienceTask?.cancel(); resilienceTask = nil
        continuation?.finish(); continuation = nil
        recognitionTask?.cancel(); recognitionTask = nil
        requestBox.clear()?.endAudio()
        await capture.stop()
        await sessionCoordinator.stopObserving()
        await sessionCoordinator.deactivate()
        ringBuffer.reset()
    }

    // MARK: - Recognition task

    /// Builds a fresh request, makes it the active one, and starts its task.
    /// Never touches the microphone tap.
    func startRecognitionTask(trigger: RestartTrigger) throws {
        guard let recognizer else { throw SpeechEngineError.engineConfigurationFailed }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        // research §R1: on-device recognition removes the ~1-minute server audio limit and the
        // whole class of network errors that made rotations constant and their cause invisible.
        request.requiresOnDeviceRecognition = Self.prefersOnDevice(recognizer)

        // Replay the carry-over window so the words spoken during the swap reach the new
        // request. With the permanent tap this is belt-and-braces rather than the load-bearing
        // mechanism it used to be.
        let carryOver = ringBuffer.drain()
        for buffer in carryOver { request.append(buffer) }

        let previous = requestBox.swap(to: request)
        let currentGeneration = generation

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
                                         errorDomain: nsError?.domain,
                                         errorCode: nsError?.code)
            }
        }

        // Tear the previous layer down only now, once the new one is already live.
        previous?.endAudio()
        telemetry.tapSwap(sessionId,
                          restartIndex: restartCount,
                          blindWindowMs: 0,   // structural: the tap was never removed
                          carryOverBuffers: carryOver.count)
        armWatchdog()
        logger.info("[AppleSFSpeech] recognition task started gen=\(currentGeneration) trigger=\(trigger.rawValue, privacy: .public)")
    }

    private func handleResult(request: SFSpeechAudioBufferRecognitionRequest,
                              text: String,
                              isFinal: Bool,
                              tokens: [TranscriptToken],
                              generation: Int,
                              errorDomain: String?,
                              errorCode: Int?) async {
        guard !isFinished else { return }
        // Ignore callbacks from a request a rotation already superseded.
        guard requestBox.isCurrent(request) || generation == self.generation else { return }

        if !text.isEmpty {
            lastTranscriptAt = MonotonicClock.now()
            armWatchdog()
            let confidence: Float = tokens.isEmpty
                ? 0.5
                : tokens.reduce(0) { $0 + $1.confidence } / Float(tokens.count)
            continuation?.yield(SpeechSegment(text: text,
                                              isFinal: isFinal,
                                              confidence: confidence,
                                              tokens: tokens,
                                              source: engineId,
                                              sessionGeneration: generation))
        }

        guard isFinal || errorDomain != nil else { return }
        telemetry.sessionEnd(sessionId,
                             reason: errorDomain != nil ? .error : .isFinal,
                             errorDomain: errorDomain,
                             errorCode: errorCode,
                             durationMs: MonotonicClock.msSince(sessionStartedAt),
                             restartIndex: restartCount)
        rotate(trigger: errorDomain != nil ? .error : .isFinal)
    }

    // MARK: - Helpers

    private nonisolated static func prefersOnDevice(_ recognizer: SFSpeechRecognizer) -> Bool {
        recognizer.supportsOnDeviceRecognition
    }
}

extension SFSpeechRecognizer {
    static func hasAuthorizationToRecognize() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
