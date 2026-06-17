//
//  TranscriptionViewModel.swift
//  TranslatorApp
//

import SwiftUI
import OSLog

/// Carries a translated sentence and its source-segment confidence for tonal opacity rendering.
struct TranslationEntry: Sendable {
    let text: String
    let minSourceConfidence: Float
}

struct TranslationRequest: Sendable {
    let text: String
    let sourceConfidence: Float
}

@MainActor
@Observable
final class TranscriptionViewModel {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "ViewModel")
    private let transcribeUseCase: TranscribeAudioUseCase
    private let saveConversationUseCase: SaveConversationUseCase
    let downloadCoordinator: BackgroundAssetsCoordinator

    // MARK: - State
    var currentBuffer: String = ""
    var isRecording: Bool = false
    var hasError: Bool = false
    var errorMessage: String?
    var translatorState: TranslatorState = .idle
    var modelInstallState: ModelInstallState = .notRequested
    var enginePreference: EnginePreference = .fromUserDefaults()

    var emittedPhrases: [String] = []
    var translatedSentences: [TranslationEntry] = []
    var translationRequests: AsyncStream<TranslationRequest>?

    var isSaving: Bool = false
    var savedSuccessfully: Bool = false
    var canSave: Bool { !isRecording && !emittedPhrases.isEmpty }

    var exportText: String {
        let en = emittedPhrases.joined(separator: " ")
        let es = translatedSentences.map(\.text).joined(separator: "\n")
        return "=== ENGLISH TRANSCRIPT ===\n\n\(en.isEmpty ? "(no transcript)" : en)\n\n=== SPANISH TRANSLATION ===\n\n\(es.isEmpty ? "(no translation)" : es)"
    }
    private static let exportDateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH-mm"; return f
    }()
    var exportDocument: ConversationExport {
        ConversationExport(content: exportText,
                           filename: "Conversation \(Self.exportDateFmt.string(from: Date())).txt")
    }

    // MARK: - Private state
    private var translationContinuation: AsyncStream<TranslationRequest>.Continuation?
    private var transcriptionTask: Task<Void, Never>?
    private var downloadStateTask: Task<Void, Never>?
    private var emittedPhraseSet: Set<String> = []
    private var commitCounter: Int = 0
    private var isRestarting: Bool = false
    var latestSegmentConfidence: Float = 1.0
    private let maxTranslated = 30
    private let maxEmitted = 50

    // MARK: - Init
    init(transcribeUseCase: TranscribeAudioUseCase,
         saveConversationUseCase: SaveConversationUseCase,
         downloadCoordinator: BackgroundAssetsCoordinator) {
        self.transcribeUseCase = transcribeUseCase
        self.saveConversationUseCase = saveConversationUseCase
        self.downloadCoordinator = downloadCoordinator
        subscribeToDownloadState()
    }

    // MARK: - Download coordinator

    private func subscribeToDownloadState() {
        downloadStateTask = Task { [weak self] in
            guard let self else { return }
            for await state in await downloadCoordinator.stateStream() {
                await MainActor.run { self.modelInstallState = state }
            }
        }
    }

    func acceptModelDownload() {
        Task { await downloadCoordinator.acceptDownload() }
    }

    func declineModelDownload() {
        Task { await downloadCoordinator.declineDownload() }
    }

    func saveEnginePreference(_ pref: EnginePreference) {
        enginePreference = pref
        pref.saveToUserDefaults()
    }

    // MARK: - Recording
    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func restartListening() {
        guard isRecording else { return }
        isRestarting = true; isRecording = false; translatorState = .idle
        translationContinuation?.finish(); translationContinuation = nil; translationRequests = nil
        transcriptionTask?.cancel(); transcriptionTask = nil
        Task { [weak self] in
            guard let self else { return }
            await transcribeUseCase.stop()
            try? await Task.sleep(nanoseconds: 300_000_000)
            startRecording(preservingSession: true)
            isRestarting = false
        }
    }

    func handleAudioInterruption() {
        translatorState = .permissionDenied
        errorMessage = "Microphone access was interrupted."
        hasError = true
        if isRecording { stopRecording() }
    }

    // MARK: - Save & Export
    func saveConversation() async {
        guard canSave, !isSaving else { return }
        isSaving = true; defer { isSaving = false }
        do {
            try await saveConversationUseCase.execute(
                englishText: emittedPhrases.joined(separator: " "),
                spanishText: translatedSentences.map(\.text).joined(separator: "\n")
            )
            savedSuccessfully = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savedSuccessfully = false
        } catch ConversationError.emptyTranscript {
            errorMessage = "Nothing to save — no speech was captured."; hasError = true
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"; hasError = true
        }
    }

    // MARK: - Recording internals
    private func startRecording(preservingSession: Bool = false) {
        if !preservingSession {
            translatedSentences.removeAll(); emittedPhrases.removeAll()
            emittedPhraseSet.removeAll(); commitCounter = 0
        }
        currentBuffer = ""; errorMessage = nil; hasError = false
        translatorState = .idle; savedSuccessfully = false; latestSegmentConfidence = 1.0

        let (stream, cont) = AsyncStream.makeStream(of: TranslationRequest.self)
        translationRequests = stream; translationContinuation = cont
        isRecording = true

        transcriptionTask = Task {
            do {
                let (rawStream, stableStream) = try await transcribeUseCase.executeBoth()
                let uiTask = Task { @MainActor in
                    for await segment in rawStream {
                        self.latestSegmentConfidence = segment.confidence
                        let committed = self.emittedPhrases.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                        let full = segment.text.trimmingCharacters(in: .whitespaces)
                        if !committed.isEmpty, full.hasPrefix(committed) {
                            self.currentBuffer = String(full.dropFirst(committed.count)).trimmingCharacters(in: .whitespaces)
                        } else if !committed.isEmpty {
                            let cw = committed.split(whereSeparator: \.isWhitespace).count
                            let aw = full.split(whereSeparator: \.isWhitespace)
                            self.currentBuffer = aw.count > cw ? aw.dropFirst(cw).joined(separator: " ") : ""
                        } else { self.currentBuffer = full }
                    }
                }
                for await sentence in stableStream {
                    self.translatorState = .inFlight
                    let conf = self.latestSegmentConfidence
                    self.translationContinuation?.yield(TranslationRequest(text: sentence, sourceConfidence: conf))
                    if self.emittedPhraseSet.insert(sentence).inserted {
                        self.emittedPhrases.append(sentence)
                        if self.emittedPhrases.count > self.maxEmitted { self.emittedPhrases.removeFirst() }
                    }
                }
                uiTask.cancel()
                if self.isRecording {
                    self.isRecording = false; self.translatorState = .idle
                    self.translationContinuation?.finish(); self.translationContinuation = nil
                }
            } catch let e as SpeechError { handleSpeechError(e) }
            catch { errorMessage = error.localizedDescription; hasError = true; translatorState = .error; isRecording = false }
        }
    }

    func stopRecording() {
        isRecording = false; translatorState = .idle
        translationContinuation?.finish(); translationContinuation = nil; translationRequests = nil
        transcriptionTask?.cancel(); transcriptionTask = nil
        Task { await transcribeUseCase.stop() }
    }

    func appendTranslation(_ translation: String, sourceConfidence: Float = 1.0) {
        let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !translatedSentences.contains(where: {
            $0.text == trimmed || trimmed.contains($0.text) || $0.text.contains(trimmed)
        }) else { translatorState = .idle; return }
        commitCounter += 1
        logger.info("[COMMIT id=\(self.commitCounter)] text='\(trimmed)'")
        translatedSentences.append(TranslationEntry(text: trimmed, minSourceConfidence: sourceConfidence))
        if translatedSentences.count > maxTranslated { translatedSentences.removeFirst() }
        translatorState = .idle
    }

    private func handleSpeechError(_ error: SpeechError) {
        switch error {
        case .notAuthorized:
            translatorState = .permissionDenied
            errorMessage = "Microphone or speech recognition access is required."
        default:
            translatorState = .error
            errorMessage = "Could not start the audio engine. Please try again."
        }
        hasError = true; isRecording = false
    }
}
