//
//  DependencyContainer.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import SwiftUI
import SwiftData
import Darwin

/// Centralized dependency graph. All long-lived instances live here for the app session.
final class DependencyContainer {

    // MARK: - Backend selection

    // Runtime check: WhisperKit requires Apple Silicon (Neural Engine).
    // Intel Macs fall back to ContinuousSpeechListener (SFSpeechRecognizer, locale "en").
    private static let usesWhisper: Bool = {
        var size = 0
        sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
        var value: Int32 = 0
        sysctlbyname("hw.optional.arm64", &value, &size, nil, 0)
        return value == 1
    }()

    // MARK: - Speech pipeline

    private let speechRepository: SpeechRepositoryProtocol
    private let nlpSegmenter: NLPSegmenterServiceProtocol
    private let qualityMetrics: QualityMetricsService
    private let transcribeUseCase: TranscribeAudioUseCase

    // WhisperKit-specific (nil on Intel Mac)
    private let whisperModelManager: WhisperModelManager?

    // SFSpeechRecognizer-specific (nil on Apple Silicon when Whisper is active)
    private let speechListener: ContinuousSpeechListener?

    // MARK: - Persistence

    let modelContainer: ModelContainer
    private let conversationRepository: ConversationRepositoryProtocol
    private let saveConversationUseCase: SaveConversationUseCase
    private let fetchConversationsUseCase: FetchConversationsUseCase

    // MARK: - ViewModels (cached — created once, reused across body re-evaluations)

    private let transcriptionViewModel: TranscriptionViewModel
    private let historyViewModel: ConversationHistoryViewModel

    init() {
        let metrics = QualityMetricsService()
        qualityMetrics = metrics

        if Self.usesWhisper {
            let manager = WhisperModelManager()
            whisperModelManager = manager
            speechListener = nil

            let listener = WhisperSpeechListener(modelManager: manager)
            speechRepository = WhisperSpeechRepository(listener: listener)
        } else {
            whisperModelManager = nil
            let listener = ContinuousSpeechListener(qualityMetrics: metrics)
            speechListener = listener
            speechRepository = SpeechRepository(listener: listener)
        }

        let segmenter = NLPSegmenterService(qualityMetrics: metrics)
        nlpSegmenter = segmenter

        transcribeUseCase = TranscribeAudioUseCase(
            repository: speechRepository,
            segmenter: nlpSegmenter,
            qualityMetrics: metrics
        )

        do {
            modelContainer = try ModelContainer(for: ConversationRecord.self)
        } catch {
            fatalError("SwiftData container initialization failed: \(error)")
        }
        let convRepo = ConversationRepository(context: modelContainer.mainContext)
        conversationRepository = convRepo
        saveConversationUseCase = SaveConversationUseCase(repository: convRepo)
        fetchConversationsUseCase = FetchConversationsUseCase(repository: convRepo)

        historyViewModel = ConversationHistoryViewModel(fetchUseCase: fetchConversationsUseCase)
        transcriptionViewModel = TranscriptionViewModel(
            transcribeUseCase: transcribeUseCase,
            saveConversationUseCase: saveConversationUseCase
        )

        bindDownloadProgress()
    }

    // MARK: - ViewModel accessors

    @MainActor
    func makeTranscriptionViewModel() -> TranscriptionViewModel { transcriptionViewModel }

    @MainActor
    func makeHistoryViewModel() -> ConversationHistoryViewModel { historyViewModel }

    // MARK: - Download progress binding

    // Bridges WhisperModelManager.downloadProgress → TranscriptionViewModel.
    // Runs for the lifetime of the container (app session).
    private func bindDownloadProgress() {
        guard let manager = whisperModelManager else { return }
        let vm = transcriptionViewModel
        Task {
            for await progress in manager.downloadProgress {
                await vm.updateDownloadProgress(progress)
            }
            // Stream exhausted — ensure UI returns to idle
            await vm.updateDownloadProgress(1.0)
        }
    }
}
