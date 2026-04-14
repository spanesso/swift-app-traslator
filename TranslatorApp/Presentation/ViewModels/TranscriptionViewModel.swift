//
//  TranscriptionViewModel.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import SwiftUI
import OSLog

@MainActor
@Observable
final class TranscriptionViewModel {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "ViewModel")
    private let transcribeUseCase: TranscribeAudioUseCase
    
    var currentBuffer: String = ""
    var translatedBuffer: String = ""
    var isRecording: Bool = false
    var hasError: Bool = false
    var errorMessage: String?
    var translatorState: TranslatorState = .idle
    
    // /CAMBIO/ Manejo de streams simplificado para evitar fugas de memoria
    var translationRequests: AsyncStream<String>?
    private var translationContinuation: AsyncStream<String>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    
    var translatedSentences: [String] = []
    var emittedPhrases: [String] = []
    private let maxTranslatedSentences = 30
    private let maxEmittedPhrases = 50

    init(transcribeUseCase: TranscribeAudioUseCase) {
        self.transcribeUseCase = transcribeUseCase
    }
    
    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }
    
    private func startRecording() {
        self.translatedSentences.removeAll()
        self.emittedPhrases.removeAll()
        self.translatedBuffer = ""
        self.currentBuffer = ""
        self.isRecording = true

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        self.translationRequests = stream
        self.translationContinuation = continuation

        transcriptionTask = Task {
            do {
                let (rawStream, stableStream) = try await transcribeUseCase.executeBoth()

                // Tarea 1: Update de UI del texto original (EN) — consume rawStream
                let uiTask = Task { @MainActor in
                    for await segment in rawStream {
                        self.currentBuffer = segment.text
                    }
                }

                // Tarea 2: Consumir frases estables del segmenter y enviarlas al motor de traducción
                for await sentence in stableStream {
                    self.translatorState = .inFlight
                    self.translationContinuation?.yield(sentence)
                    self.emittedPhrases.append(sentence)
                    if self.emittedPhrases.count > self.maxEmittedPhrases {
                        self.emittedPhrases.removeFirst()
                    }
                }

                uiTask.cancel()
            } catch {
                self.errorMessage = error.localizedDescription
                self.hasError = true
                self.isRecording = false
            }
        }
    }
    
    func stopRecording() {
        isRecording = false
        translatorState = .idle
        translationContinuation?.finish()
        transcriptionTask?.cancel()
        Task { await transcribeUseCase.stop() }
    }
    
    @MainActor
    func appendTranslation(_ translation: String) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // /CAMBIO/ Evitar duplicados exactos o contenidos
        if let last = translatedSentences.last, (last == trimmed || trimmed.contains(last)) {
            self.translatorState = .idle
            return
        }
        
        logger.info("✅ [ViewModel] Unique Translation Added: \(trimmed)")
        translatedSentences.append(trimmed)
        
        if translatedSentences.count > maxTranslatedSentences {
            translatedSentences.removeFirst()
        }
        
        // /CAMBIO/ El buffer se actualiza, lo que disparará el scroll en la View
        self.translatedBuffer = translatedSentences.joined(separator: "\n\n")
        self.translatorState = .idle
    }
}
