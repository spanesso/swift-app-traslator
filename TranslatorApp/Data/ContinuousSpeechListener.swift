
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
    //  Logger estructurado
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Speech")
    
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    
    private var rawFullTranscript: String = ""
    private var continuation: AsyncStream<SpeechSegment>.Continuation?
    
    //  Tracking para métricas de calidad
    private var lastTranscriptUpdate: Date?
    private var previousTranscript: String = ""
    private let qualityMetrics: QualityMetricsService
    
    //  Constructor con inyección de métricas
    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
        super.init()
    }
    
    func start() throws -> AsyncStream<SpeechSegment> {
        //  Generamos sessionId único
        let sessionId = UUID().uuidString
        logger.info("🎤 [Speech] Starting session \(sessionId)")
        
        stop()
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
    
    //  Setup con sessionId para tracking
    private func setupRecognition(sessionId: String) throws {
        recognitionRequest = SFSpeechAudioBufferRecognitionRequest()
        guard let recognitionRequest = recognitionRequest else {
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
        
        audioEngine.prepare()
        try audioEngine.start()
        
        logger.info("🎙️ [Speech] Recognition started for session \(sessionId)")
        
        recognitionTask = speechRecognizer?.recognitionTask(with: recognitionRequest) { [weak self] result, error in
            guard let self = self else { return }
            Task {
                if let result = result {
                    let avgConfidence = self.calculateAverageConfidence(from: result)
                    
                    //  Solo actualizamos si hay texto real para procesar
                    let text = result.bestTranscription.formattedString
                    if !text.isEmpty {
                        await self.updateTranscript(
                            with: text,
                            isFinal: result.isFinal,
                            confidence: avgConfidence,
                            sessionId: sessionId
                        )
                    }
                }
                if error != nil {
                    await self.logger.error("❌ [Speech] Recognition error: \(String(describing: error))")
                    await self.handleError()
                }
            }
        }
    }
    
    //  Cálculo de confianza promedio del ASR
    private func calculateAverageConfidence(from result: SFSpeechRecognitionResult) -> Float {
        let segments = result.bestTranscription.segments
        guard !segments.isEmpty else { return 0.0 }
        
        let totalConfidence = segments.reduce(0.0) { $0 + $1.confidence }
        return totalConfidence / Float(segments.count)
    }
    
    private func emit(text: String, isFinal: Bool) {
        continuation?.yield(SpeechSegment(text: text, isFinal: isFinal))
    }
    
    //  Update con métricas de calidad
    private func updateTranscript(with text: String, isFinal: Bool, confidence: Float, sessionId: String) {
        let now = Date()
        
        //  Detectar revisiones (texto cambió)
        let didChange = text != previousTranscript
        
        if didChange && !previousTranscript.isEmpty {
            logger.debug("🔄 [Speech] Revision detected | prev_len=\(self.previousTranscript.count) new_len=\(text.count)")
            
            //  Registrar revisión en métricas
            Task {
                await qualityMetrics.recordRevision(sessionId: sessionId)
            }
        }
        
        //  Calcular estabilidad (tiempo desde última actualización)
        if let lastUpdate = lastTranscriptUpdate {
            let stabilityDelay = now.timeIntervalSince(lastUpdate)
            
            Task {
                await qualityMetrics.recordStabilityDelay(stabilityDelay, sessionId: sessionId)
            }
        }
        
        //  Calcular velocidad de habla (palabras por segundo)
        let words = text.split(separator: " ")
        if let lastUpdate = lastTranscriptUpdate, !words.isEmpty {
            let timeWindow = now.timeIntervalSince(lastUpdate)
            if timeWindow > 0 {
                let wordsPerSecond = Double(words.count) / timeWindow
                
                Task {
                    await qualityMetrics.recordWordsPerSecond(wordsPerSecond, sessionId: sessionId)
                }
            }
        }
        
        //  Registrar confianza del ASR
        Task {
            await qualityMetrics.recordConfidence(confidence, sessionId: sessionId)
        }
        
        //  Detectar fragmentación (palabras truncadas, repeticiones)
        let fragmentationScore = calculateFragmentation(text: text)
        Task {
            await qualityMetrics.recordFragmentation(fragmentationScore, sessionId: sessionId)
        }
        
        self.rawFullTranscript = text
        self.previousTranscript = text
        self.lastTranscriptUpdate = now
        
        let segment = SpeechSegment(text: text, isFinal: isFinal, confidence: confidence)
        continuation?.yield(segment)
        
        logger.debug("📝 [Speech] Transcript updated | len=\(text.count) final=\(isFinal) conf=\(String(format: "%.2f", confidence))")
    }
    
    //  Heurística para detectar fragmentación
    private func calculateFragmentation(text: String) -> Double {
        let words = text.split(separator: " ")
        guard !words.isEmpty else { return 0.0 }
        
        var fragmentCount = 0
        
        // Detectar palabras muy cortas (posibles truncamientos)
        for word in words {
            if word.count <= 2 && !["a", "I", "an", "to", "in", "on", "is", "it", "he", "we"].contains(word.lowercased()) {
                fragmentCount += 1
            }
        }
        
        // Detectar repeticiones consecutivas
        for i in 0..<(words.count - 1) {
            if words[i].lowercased() == words[i + 1].lowercased() {
                fragmentCount += 1
            }
        }
        
        return Double(fragmentCount) / Double(words.count)
    }
    
    private func handleError() {
        logger.error("❌ [Speech] Error handled, stopping stream")
        continuation?.finish()
        stop()
    }
    
    func stop() {
        logger.info("🛑 [Speech] Stopping recognition")
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        recognitionTask?.cancel()
        recognitionRequest = nil
        recognitionTask = nil
        continuation = nil
        lastTranscriptUpdate = nil
        previousTranscript = ""
    }
}
