//
//  ContinuousSpeechListener.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import Speech
import AVFoundation
import OSLog

actor ContinuousSpeechListener: NSObject {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Speech")

    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    private var rawFullTranscript: String = ""
    private var continuation: AsyncStream<SpeechSegment>.Continuation?
    private var isFinished: Bool = false

    private var lastTranscriptUpdate: Date?
    private var previousTranscript: String = ""
    private let qualityMetrics: QualityMetricsService

    private var currentSessionId: String = ""
    private var restartCount: Int = 0
    private var isRestarting: Bool = false
    private var watchdogTask: Task<Void, Never>?

    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
        super.init()
    }

    func start() throws -> AsyncStream<SpeechSegment> {
        let sessionId = UUID().uuidString
        currentSessionId = sessionId
        logger.info("🎤 [Speech] Starting session \(sessionId)")

        stop()

        isFinished = false
        restartCount = 0
        let stream = AsyncStream<SpeechSegment> { continuation in
            self.continuation = continuation
        }
        try configureAudioSession()
        try setupRecognition(sessionId: sessionId)
        return stream
    }

    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try session.setActive(true, options: .notifyOthersOnDeactivation)
        logger.debug("🔊 [Speech] Audio session configured")
    }

    private func setupRecognition(sessionId: String) throws {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest else {
            logger.error("❌ [Speech] Failed to create recognition request")
            throw SpeechError.engineConfigurationFailed
        }
        recognitionRequest.shouldReportPartialResults = true

        let inputNode = audioEngine.inputNode
        let recordingFormat = inputNode.outputFormat(forBus: 0)
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: recordingFormat) { buffer, _ in
            recognitionRequest.append(buffer)
        }

        if !audioEngine.isRunning { audioEngine.prepare(); try audioEngine.start() }

        logger.info("🎙️ [Speech] Recognition task started for session \(sessionId)")
        scheduleWatchdog()

        // Extract all needed values from the ObjC result before crossing into the actor.
        // This avoids Sendable warnings for SFSpeechRecognitionResult in Swift 6 strict mode.
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self else { return }
            let isFinal = result?.isFinal ?? false
            let text = result?.bestTranscription.formattedString ?? ""
            let segments = result?.bestTranscription.segments ?? []
            let avgConfidence: Float = segments.isEmpty ? 0.0 :
                segments.reduce(0.0) { $0 + $1.confidence } / Float(segments.count)

            Task { [weak self] in
                guard let self else { return }
                if !text.isEmpty {
                    await self.updateTranscript(with: text, isFinal: isFinal,
                                                confidence: avgConfidence, sessionId: sessionId)
                }
                if isFinal || error != nil {
                    if await self.isFinished {
                        // User-initiated stop — do nothing.
                    } else {
                        await self.restartRecognition()
                    }
                }
            }
        }
    }

    // MARK: - Watchdog

    // Fires 65 s after each recognition session start. SFSpeechRecognizer times out at ~60 s,
    // so a healthy session always resets this before it fires. If it fires, the audio pipeline
    // has frozen and we force a full restart.
    private func scheduleWatchdog() {
        watchdogTask?.cancel()
        watchdogTask = Task {
            try? await Task.sleep(nanoseconds: 65_000_000_000)
            guard !Task.isCancelled, !isFinished, !isRestarting else { return }
            logger.warning("⚠️ [Speech] Watchdog triggered — no activity in 65 s, forcing restart")
            restartRecognition()
        }
    }

    // MARK: - Restart

    private func restartRecognition() {
        // Guard against concurrent restarts (both callback-triggered and watchdog-triggered).
        guard !isRestarting else { return }
        isRestarting = true
        watchdogTask?.cancel()
        watchdogTask = nil
        restartCount += 1
        logger.info("🔄 [Speech] Restarting (#\(self.restartCount)) session \(self.currentSessionId)")

        // Tear down recognition layer.
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest?.endAudio()
        recognitionRequest = nil

        // Stop the audio engine completely so the next installTap starts with a clean slate.
        // Leaving it running while swapping taps silently breaks audio delivery on macOS.
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)

        Task {
            // Give the engine time to fully stop before restarting.
            try? await Task.sleep(nanoseconds: 200_000_000) // 200 ms
            guard !isFinished else { isRestarting = false; return }
            do {
                try configureAudioSession()
                try setupRecognition(sessionId: currentSessionId)
            } catch {
                logger.error("❌ [Speech] Restart failed: \(error) — terminating stream")
                handleError()
            }
            isRestarting = false
        }
    }

    // MARK: - Transcript processing

    private func updateTranscript(with text: String, isFinal: Bool, confidence: Float, sessionId: String) {
        guard !isFinished else { return }
        let now = Date()

        let didChange = text != previousTranscript
        if didChange && !previousTranscript.isEmpty {
            logger.debug("🔄 [Speech] Revision | prev=\(self.previousTranscript.count) new=\(text.count)")
            Task { await qualityMetrics.recordRevision(sessionId: sessionId) }
        }

        if let lastUpdate = lastTranscriptUpdate {
            let stabilityDelay = now.timeIntervalSince(lastUpdate)
            Task { await qualityMetrics.recordStabilityDelay(stabilityDelay, sessionId: sessionId) }
        }

        let words = text.split(separator: " ")
        if let lastUpdate = lastTranscriptUpdate, !words.isEmpty {
            let timeWindow = now.timeIntervalSince(lastUpdate)
            if timeWindow > 0 {
                Task { await qualityMetrics.recordWordsPerSecond(Double(words.count) / timeWindow, sessionId: sessionId) }
            }
        }

        Task { await qualityMetrics.recordConfidence(confidence, sessionId: sessionId) }
        Task { await qualityMetrics.recordFragmentation(calculateFragmentation(text: text), sessionId: sessionId) }

        rawFullTranscript = text
        previousTranscript = text
        lastTranscriptUpdate = now

        continuation?.yield(SpeechSegment(text: text, isFinal: isFinal, confidence: confidence))
        logger.debug("📝 [Speech] Transcript | len=\(text.count) final=\(isFinal) conf=\(String(format: "%.2f", confidence))")
    }

    private func calculateFragmentation(text: String) -> Double {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return 0.0 }
        let commonShortWords: Set<String> = ["a", "i", "an", "to", "in", "on", "is", "it", "he", "we"]
        var fragmentCount = 0
        for word in words where word.count <= 2 && !commonShortWords.contains(word.lowercased()) {
            fragmentCount += 1
        }
        for i in 0..<(words.count - 1) where words[i].lowercased() == words[i + 1].lowercased() {
            fragmentCount += 1
        }
        return Double(fragmentCount) / Double(words.count)
    }

    private func handleError() {
        guard !isFinished else { return }
        logger.error("❌ [Speech] Error handled, stopping stream")
        finishStream()
        stopAudio()
    }

    // MARK: - Stream lifecycle

    private func finishStream() {
        guard !isFinished else { return }
        isFinished = true
        continuation?.finish()
        continuation = nil
    }

    func stop() {
        logger.info("🛑 [Speech] Stopping (total restarts: \(self.restartCount))")
        watchdogTask?.cancel()
        watchdogTask = nil
        isRestarting = false
        finishStream()
        stopAudio()
        lastTranscriptUpdate = nil
        previousTranscript = ""
        rawFullTranscript = ""
    }

    private func stopAudio() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
    }
}
