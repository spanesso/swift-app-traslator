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
    // O(1) duplicate guard for emittedPhrases
    private var emittedPhraseSet: Set<String> = []
    // Incrementing ID for commit logs
    private var commitCounter: Int = 0

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
        self.emittedPhraseSet.removeAll()
        self.translatedBuffer = ""
        self.currentBuffer = ""
        self.commitCounter = 0
        self.isRecording = true

        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        self.translationRequests = stream
        self.translationContinuation = continuation

        transcriptionTask = Task {
            do {
                let (rawStream, stableStream) = try await transcribeUseCase.executeBoth()

                // Task 1: Update original column — show only uncommitted tail
                let uiTask = Task { @MainActor in
                    for await segment in rawStream {
                        let committedText = self.emittedPhrases.joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces)
                        let fullText = segment.text.trimmingCharacters(in: .whitespaces)

                        if segment.isFinal {
                            self.logger.info("[ASR-FINAL] \(fullText)")
                        } else {
                            self.logger.debug("[ASR-PARTIAL] \(fullText)")
                        }

                        if !committedText.isEmpty, fullText.hasPrefix(committedText) {
                            let tail = String(fullText.dropFirst(committedText.count))
                                .trimmingCharacters(in: .whitespaces)
                            self.currentBuffer = tail
                        } else if !committedText.isEmpty {
                            // ASR revised committed text: skip by word count
                            let committedWordCount = committedText
                                .split(whereSeparator: \.isWhitespace).count
                            let allWords = fullText.split(whereSeparator: \.isWhitespace)
                            if allWords.count > committedWordCount {
                                self.currentBuffer = allWords
                                    .dropFirst(committedWordCount)
                                    .joined(separator: " ")
                            } else {
                                self.currentBuffer = ""
                            }
                        } else {
                            self.currentBuffer = fullText
                        }
                    }
                }

                // Task 2: Stable phrases → translation engine (no context injection)
                for await sentence in stableStream {
                    self.translatorState = .inFlight
                    self.logger.info("[BUFFER-APPEND] sentence='\(sentence)'")
                    // Send the sentence directly — no context prefix to avoid leaking into translation
                    self.translationContinuation?.yield(sentence)
                    // Deduplicate before appending to emittedPhrases
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

    @MainActor
    func appendTranslation(_ translation: String) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Full-array dedup — exact match, new is subset of old, old is subset of new
        guard !translatedSentences.contains(where: {
            $0 == trimmed || trimmed.contains($0) || $0.contains(trimmed)
        }) else {
            self.translatorState = .idle
            return
        }

        let id = commitCounter
        commitCounter += 1
        logger.info("[COMMIT id=\(id) text='\(trimmed)']")
        translatedSentences.append(trimmed)

        if translatedSentences.count > maxTranslatedSentences {
            translatedSentences.removeFirst()
        }

        self.translatedBuffer = translatedSentences.joined(separator: "\n\n")
        self.translatorState = .idle
    }
}
