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
    private let saveConversationUseCase: SaveConversationUseCase

    // MARK: - Published state
    var currentBuffer: String = ""
    var isRecording: Bool = false
    var hasError: Bool = false
    var errorMessage: String?
    var translatorState: TranslatorState = .idle

    var emittedPhrases: [String] = []
    var translatedSentences: [String] = []
    var translationRequests: AsyncStream<String>?

    // MARK: - Save / export state
    var isSaving: Bool = false
    var savedSuccessfully: Bool = false
    var canSave: Bool { !isRecording && !emittedPhrases.isEmpty }

    var exportText: String {
        let en = emittedPhrases.joined(separator: " ")
        let es = translatedSentences.joined(separator: "\n")
        let enDisplay = en.isEmpty ? "(no transcript)" : en
        let esDisplay = es.isEmpty ? "(no translation)" : es
        return "=== ENGLISH TRANSCRIPT ===\n\n\(enDisplay)\n\n=== SPANISH TRANSLATION ===\n\n\(esDisplay)"
    }
    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"; return f
    }()
    var exportDocument: ConversationExport {
        ConversationExport(content: exportText,
                           filename: "Conversation \(Self.exportDateFormatter.string(from: Date())).txt")
    }

    // MARK: - Private state
    private var translationContinuation: AsyncStream<String>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var emittedPhraseSet: Set<String> = []
    private var commitCounter: Int = 0
    private var isRestarting: Bool = false
    private let maxTranslatedSentences = 30
    private let maxEmittedPhrases = 50

    // MARK: - Init
    init(transcribeUseCase: TranscribeAudioUseCase, saveConversationUseCase: SaveConversationUseCase) {
        self.transcribeUseCase = transcribeUseCase
        self.saveConversationUseCase = saveConversationUseCase
    }

    // MARK: - Public API
    func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    func restartListening() {
        guard isRecording else { return }
        isRestarting = true
        isRecording = false
        translatorState = .idle
        translationContinuation?.finish()
        translationContinuation = nil
        translationRequests = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        Task { [weak self] in
            guard let self else { return }
            await transcribeUseCase.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            startRecording(preservingSession: true)
            isRestarting = false
        }
    }

    // MARK: - Save & Export
    func saveConversation() async {
        guard canSave, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await saveConversationUseCase.execute(
                englishText: emittedPhrases.joined(separator: " "),
                spanishText: translatedSentences.joined(separator: "\n")
            )
            logger.info("[SAVE] Conversation saved successfully")
            savedSuccessfully = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savedSuccessfully = false
        } catch ConversationError.emptyTranscript {
            errorMessage = "Nothing to save — no speech was captured."
            hasError = true
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            hasError = true
        }
    }

    // MARK: - Recording control
    private func startRecording(preservingSession: Bool = false) {
        if !preservingSession {
            translatedSentences.removeAll()
            emittedPhrases.removeAll()
            emittedPhraseSet.removeAll()
            commitCounter = 0
        }
        currentBuffer = ""
        errorMessage = nil
        hasError = false
        translatorState = .idle
        savedSuccessfully = false

        // Stream must be assigned before isRecording = true (onChange reads it immediately)
        let (stream, continuation) = AsyncStream.makeStream(of: String.self)
        translationRequests = stream
        translationContinuation = continuation

        isRecording = true

        transcriptionTask = Task {
            do {
                let (rawStream, stableStream) = try await transcribeUseCase.executeBoth()

                let uiTask = Task { @MainActor in
                    for await segment in rawStream {
                        let committedText = self.emittedPhrases
                            .joined(separator: " ")
                            .trimmingCharacters(in: .whitespaces)
                        let fullText = segment.text.trimmingCharacters(in: .whitespaces)

                        if segment.isFinal {
                            self.logger.info("[ASR-FINAL] \(fullText)")
                        } else {
                            self.logger.debug("[ASR-PARTIAL] \(fullText)")
                        }

                        if !committedText.isEmpty, fullText.hasPrefix(committedText) {
                            self.currentBuffer = String(fullText.dropFirst(committedText.count))
                                .trimmingCharacters(in: .whitespaces)
                        } else if !committedText.isEmpty {
                            // ASR revised already-committed text — skip by word count
                            let committedWordCount = committedText
                                .split(whereSeparator: \.isWhitespace).count
                            let allWords = fullText.split(whereSeparator: \.isWhitespace)
                            self.currentBuffer = allWords.count > committedWordCount
                                ? allWords.dropFirst(committedWordCount).joined(separator: " ")
                                : ""
                        } else {
                            self.currentBuffer = fullText
                        }
                    }
                }

                for await sentence in stableStream {
                    self.translatorState = .inFlight
                    self.logger.info("[BUFFER-APPEND] sentence='\(sentence)'")
                    self.translationContinuation?.yield(sentence)

                    if self.emittedPhraseSet.insert(sentence).inserted {
                        self.emittedPhrases.append(sentence)
                        if self.emittedPhrases.count > self.maxEmittedPhrases {
                            self.emittedPhrases.removeFirst()
                        }
                    }
                }

                uiTask.cancel()
            } catch let speechError as SpeechError {
                self.handleSpeechError(speechError)
            } catch {
                self.errorMessage = error.localizedDescription
                self.hasError = true
                self.translatorState = .error
                self.isRecording = false
            }
        }
    }

    func stopRecording() {
        // Stop order matters: UI state → streams → tasks → audio engine
        isRecording = false
        translatorState = .idle
        translationContinuation?.finish()
        translationContinuation = nil
        translationRequests = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        Task { await transcribeUseCase.stop() }
    }

    @MainActor
    func appendTranslation(_ translation: String) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        guard !translatedSentences.contains(where: {
            $0 == trimmed || trimmed.contains($0) || $0.contains(trimmed)
        }) else {
            self.translatorState = .idle
            return
        }

        let id = commitCounter
        commitCounter += 1
        logger.info("[COMMIT id=\(id)] text='\(trimmed)'")
        translatedSentences.append(trimmed)

        if translatedSentences.count > maxTranslatedSentences {
            translatedSentences.removeFirst()
        }
        self.translatorState = .idle
    }

    // MARK: - Model download progress

    func updateDownloadProgress(_ progress: Double) {
        if progress >= 1.0 {
            if case .modelDownloading = translatorState { translatorState = .idle }
        } else {
            translatorState = .modelDownloading(progress: progress)
        }
    }

    // MARK: - Error handling

    private func handleSpeechError(_ error: SpeechError) {
        switch error {
        case .notAuthorized:
            self.translatorState = .permissionDenied
            self.errorMessage = "Microphone or speech recognition access is required. Please enable it in System Settings → Privacy & Security."
        case .engineConfigurationFailed:
            self.translatorState = .error
            self.errorMessage = "Could not start the audio engine. Please try again."
        }
        self.hasError = true
        self.isRecording = false
    }
}
