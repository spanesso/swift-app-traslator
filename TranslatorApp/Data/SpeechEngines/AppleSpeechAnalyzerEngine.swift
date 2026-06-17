//
//  AppleSpeechAnalyzerEngine.swift
//  TranslatorApp
//
//  Tier 0 — Apple on-device speech recognition with per-segment token confidence.
//  Uses SFSpeechRecognizer (available on all supported iOS versions) and maps each
//  SFTranscriptionSegment to a TranscriptToken so the confidence UI works on every device.

import Speech
import AVFoundation
import OSLog

actor AppleSpeechAnalyzerEngine: SpeechEngineProtocol {
    let engineId: EngineId = .appleSpeechAnalyzer
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "AppleSpeech")

    private var recognizer: SFSpeechRecognizer?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private let audioEngine = AVAudioEngine()
    private var continuation: AsyncStream<SpeechSegment>.Continuation?
    private var restartTask: Task<Void, Never>?
    private var isFinished = false
    private var restartCount = 0
    private var sessionLocale = "en-US"

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        guard await SFSpeechRecognizer.hasAuthorizationToRecognize() else {
            throw SpeechEngineError.notAuthorized
        }
        sessionLocale = options.locale
        recognizer = SFSpeechRecognizer(locale: Locale(identifier: options.locale))
        isFinished = false
        restartCount = 0
        logger.info("[AppleSpeech] start locale=\(options.locale)")

        let stream = AsyncStream<SpeechSegment> { [weak self] cont in
            Task { [weak self] in await self?.setContinuation(cont) }
        }
        try await configureAndStart()
        return stream
    }

    func stop() async {
        logger.info("[AppleSpeech] stop (restarts=\(self.restartCount))")
        isFinished = true
        restartTask?.cancel()
        continuation?.finish()
        continuation = nil
        teardownAudio()
    }

    private func setContinuation(_ cont: AsyncStream<SpeechSegment>.Continuation) {
        continuation = cont
    }

    private func configureAndStart() async throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            throw SpeechEngineError.engineConfigurationFailed
        }

        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let req = recognitionRequest else { throw SpeechEngineError.engineConfigurationFailed }
        req.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let fmt = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: fmt) { [weak self] buf, _ in
            self?.recognitionRequest?.append(buf)
        }
        audioEngine.prepare()
        try audioEngine.start()

        recognitionTask = recognizer?.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            let isFinal = result?.isFinal ?? false
            let text = result?.bestTranscription.formattedString ?? ""
            let segs = result?.bestTranscription.segments ?? []
            let tokens = segs.map { seg -> TranscriptToken in
                TranscriptToken(text: seg.substring,
                                confidence: max(0, min(1, seg.confidence)),
                                startTime: seg.timestamp,
                                endTime: seg.timestamp + seg.duration)
            }
            let conf: Float = tokens.isEmpty ? 0.5 : tokens.reduce(0) { $0 + $1.confidence } / Float(tokens.count)

            Task { [weak self] in
                guard let self, !text.isEmpty else { return }
                await self.emit(SpeechSegment(text: text, isFinal: isFinal,
                                              confidence: conf, tokens: tokens,
                                              source: .appleSpeechAnalyzer))
                let needsRestart = isFinal || error != nil
                let finished = await self.isFinished
                if needsRestart && !finished {
                    await self.scheduleRestart()
                }
            }
        }
    }

    private func emit(_ segment: SpeechSegment) {
        continuation?.yield(segment)
    }

    private func scheduleRestart() {
        guard !isFinished else { return }
        restartCount += 1
        logger.info("[AppleSpeech] scheduling restart #\(self.restartCount)")
        restartTask = Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard !Task.isCancelled, !isFinished else { return }
            recognitionTask?.cancel()
            recognitionRequest?.endAudio()
            recognitionRequest = nil
            recognitionTask = nil
            try? await configureAndStart()
        }
    }

    private func teardownAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
}

private extension SFSpeechRecognizer {
    static func hasAuthorizationToRecognize() async -> Bool {
        await withCheckedContinuation { cont in
            requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
