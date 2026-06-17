//
//  WhisperKitEngine.swift
//  TranslatorApp
//
//  Tier 1 engine — WhisperKit large-v3-turbo (compressed, on-device, A17 Pro+ via ANE).
//  Buffers PCM audio from AVAudioEngine and submits 2-second windows to WhisperKit for
//  transcription. Emits hypothesis segments during buffering and final segments when stable.
//
//  Requires: WhisperKit SPM package added to the TranslatorApp target.

import AVFoundation
import OSLog
import WhisperKit

actor WhisperKitEngine: SpeechEngineProtocol {
    let engineId: EngineId = .whisperKitTurbo
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "WhisperKit")
    private let vadGate = VADGate()

    private var whisperKit: WhisperKit?
    private var audioEngine: AVAudioEngine?
    private var continuation: AsyncStream<SpeechSegment>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var isRunning = false
    private var audioBuffer: [Float] = []
    private let sampleRate: Double = 16000
    private let windowSizeSeconds: Double = 2.0

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        guard !isRunning else {
            logger.warning("[WhisperKit] start called while already running")
            throw SpeechEngineError.engineConfigurationFailed
        }
        logger.info("[WhisperKit] loading model large-v3-turbo")
        do {
            whisperKit = try await WhisperKit(WhisperKitConfig(model: "large-v3-turbo",
                                                               verbose: false,
                                                               logLevel: .error))
        } catch {
            logger.error("[WhisperKit] model load failed: \(error)")
            throw SpeechEngineError.modelUnavailable
        }
        logger.info("[WhisperKit] model loaded — starting audio capture")

        let (stream, cont) = AsyncStream.makeStream(of: SpeechSegment.self)
        continuation = cont
        isRunning = true
        audioBuffer = []
        try setupAudio()
        scheduleTranscriptionLoop()
        return await vadGate.filter(stream)
    }

    func stop() async {
        logger.info("[WhisperKit] stop")
        isRunning = false
        transcriptionTask?.cancel()
        transcriptionTask = nil
        teardownAudio()
        continuation?.finish()
        continuation = nil
        audioBuffer = []
    }

    // MARK: - Audio capture

    private func setupAudio() throws {
        let engine = AVAudioEngine()
        audioEngine = engine
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)

        let inputNode = engine.inputNode
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: sampleRate,
                                   channels: 1,
                                   interleaved: false)!
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let channelData = buffer.floatChannelData?[0] else { return }
            let frames = Array(UnsafeBufferPointer(start: channelData, count: Int(buffer.frameLength)))
            Task { [weak self] in await self?.appendAudio(frames) }
        }
        engine.prepare()
        try engine.start()
    }

    private func appendAudio(_ frames: [Float]) {
        audioBuffer.append(contentsOf: frames)
    }

    private func teardownAudio() {
        audioEngine?.stop()
        audioEngine?.inputNode.removeTap(onBus: 0)
        audioEngine = nil
    }

    // MARK: - Transcription loop

    private func scheduleTranscriptionLoop() {
        transcriptionTask = Task {
            let windowFrames = Int(sampleRate * windowSizeSeconds)
            while isRunning && !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(windowSizeSeconds * 1_000_000_000))
                guard isRunning && !Task.isCancelled else { break }
                let chunk = self.audioBuffer
                if chunk.count >= windowFrames / 4 { // at least 0.5s of audio
                    await transcribeChunk(chunk)
                }
            }
            // Final transcription of remaining buffer
            if !audioBuffer.isEmpty {
                await transcribeChunk(audioBuffer, isFinalFlush: true)
            }
        }
    }

    private func transcribeChunk(_ chunk: [Float], isFinalFlush: Bool = false) async {
        guard let kit = whisperKit else { return }
        do {
            let options = DecodingOptions(
                task: .transcribe,
                language: "en",
                wordTimestamps: true,
                firstTokenLogProbThreshold: -1.5
            )
            let results = try await kit.transcribe(audioArray: chunk, decodeOptions: options)
            guard let result = results.first else { return }
            let rawText = result.text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            guard !rawText.isEmpty else { return }

            let wordTimings = result.segments.flatMap { $0.words ?? [] }
            let tokens = wordTimings.map { w in
                TranscriptToken(text: w.word,
                                confidence: Float(w.probability),
                                startTime: TimeInterval(w.start),
                                endTime: TimeInterval(w.end))
            }
            let conf: Float = tokens.isEmpty
                ? 0.5
                : tokens.reduce(0) { $0 + $1.confidence } / Float(tokens.count)

            let segment = SpeechSegment(
                text: rawText,
                isFinal: isFinalFlush,
                confidence: conf,
                tokens: tokens,
                source: .whisperKitTurbo,
                isHypothesis: !isFinalFlush
            )
            continuation?.yield(segment)
            if isFinalFlush { audioBuffer = [] }
            let confStr = String(format: "%.2f", conf)
            logger.debug("[WhisperKit] \(tokens.count) tokens isFinal=\(isFinalFlush) conf=\(confStr)")
        } catch {
            logger.error("[WhisperKit] transcription error: \(error)")
        }
    }

}
