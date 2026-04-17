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

    var translationRequests: AsyncStream<String>?
    private var translationContinuation: AsyncStream<String>.Continuation?
    private var transcriptionTask: Task<Void, Never>?

    var translatedSentences: [String] = []
    var emittedPhrases: [String] = []
    // T006: O(1) duplicate guard for emittedPhrases
    private var emittedPhraseSet: Set<String> = []
    // T011: context window for context-aware translation
    private var translationContext = TranslationContextWindow()

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
        self.emittedPhraseSet.removeAll()       // T006: reset per session
        self.translationContext = TranslationContextWindow()  // T011: reset per session
        self.translatedBuffer = ""
        self.currentBuffer = ""
        self.isRecording = true

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        self.translationRequests = stream
        self.translationContinuation = continuation

        transcriptionTask = Task {
            do {
                let (rawStream, stableStream) = try await transcribeUseCase.executeBoth()

                // Task 1: Update original column — show only uncommitted tail (T007)
                let uiTask = Task { @MainActor in
                    for await segment in rawStream {
                        // Compute committed prefix from already-emitted phrases
                        let committedText = self.emittedPhrases.joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces)
                        let fullText = segment.text.trimmingCharacters(in: .whitespaces)
                        if !committedText.isEmpty, fullText.hasPrefix(committedText) {
                            let tail = String(fullText.dropFirst(committedText.count))
                                .trimmingCharacters(in: .whitespaces)
                            self.currentBuffer = tail
                        } else {
                            self.currentBuffer = fullText
                        }
                    }
                }

                // Task 2: Stable phrases → translation engine with context injection (T014)
                for await sentence in stableStream {
                    self.translatorState = .inFlight
                    // T014: yield request with context block prepended
                    self.translationContinuation?.yield(self.translationContext.requestText(for: sentence))
                    // T006: deduplicate before appending to emittedPhrases
                    if self.emittedPhraseSet.insert(sentence).inserted {
                        self.emittedPhrases.append(sentence)
                        if self.emittedPhrases.count > self.maxEmittedPhrases {
                            self.emittedPhrases.removeFirst()
                        }
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

    // T012: originalSentence added so context window can record the (original, translated) pair
    @MainActor
    func appendTranslation(_ translation: String, originalSentence: String) {
        // T017: whitespace guard
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // T016: full-array dedup — exact match, new is subset of old, old is subset of new
        guard !translatedSentences.contains(where: {
            $0 == trimmed || trimmed.contains($0) || $0.contains(trimmed)
        }) else {
            self.translatorState = .idle
            return
        }

        logger.info("✅ [ViewModel] Unique Translation Added: \(trimmed)")
        // T012: record pair in context window for future requests
        translationContext.append(original: originalSentence, translated: trimmed)
        translatedSentences.append(trimmed)

        if translatedSentences.count > maxTranslatedSentences {
            translatedSentences.removeFirst()
        }

        self.translatedBuffer = translatedSentences.joined(separator: "\n\n")
        self.translatorState = .idle
    }
}
