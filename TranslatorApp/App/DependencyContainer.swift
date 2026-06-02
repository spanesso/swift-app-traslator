//
//  DependencyContainer.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import SwiftUI
import SwiftData

/// Centralized dependency graph. All long-lived instances live here for the app session.
final class DependencyContainer {

    // MARK: - Speech pipeline

    private let speechListener: ContinuousSpeechListener
    private let speechRepository: SpeechRepositoryProtocol
    private let nlpSegmenter: NLPSegmenterServiceProtocol
    private let qualityMetrics: QualityMetricsService
    private let transcribeUseCase: TranscribeAudioUseCase

    // MARK: - Persistence

    let modelContainer: ModelContainer
    private let conversationRepository: ConversationRepositoryProtocol
    private let saveConversationUseCase: SaveConversationUseCase
    private let fetchConversationsUseCase: FetchConversationsUseCase

    // MARK: - ViewModels (cached — created once, reused across body re-evaluations)

    private let transcriptionViewModel: TranscriptionViewModel
    private let historyViewModel: ConversationHistoryViewModel

    init() {
        // Speech pipeline
        let metrics = QualityMetricsService()
        qualityMetrics = metrics

        let listener = ContinuousSpeechListener(qualityMetrics: metrics)
        speechListener = listener
        speechRepository = SpeechRepository(listener: listener)

        let segmenter = NLPSegmenterService(qualityMetrics: metrics)
        nlpSegmenter = segmenter

        transcribeUseCase = TranscribeAudioUseCase(
            repository: speechRepository,
            segmenter: nlpSegmenter,
            qualityMetrics: metrics
        )

        // Persistence — fatalError is appropriate here: a failed SwiftData container
        // means the app cannot function and there is nothing to recover from.
        do {
            modelContainer = try ModelContainer(for: ConversationRecord.self)
        } catch {
            fatalError("SwiftData container initialization failed: \(error)")
        }
        let convRepo = ConversationRepository(context: modelContainer.mainContext)
        conversationRepository = convRepo
        saveConversationUseCase = SaveConversationUseCase(repository: convRepo)
        fetchConversationsUseCase = FetchConversationsUseCase(repository: convRepo)

        // ViewModels
        historyViewModel = ConversationHistoryViewModel(fetchUseCase: fetchConversationsUseCase)
        transcriptionViewModel = TranscriptionViewModel(
            transcribeUseCase: transcribeUseCase,
            saveConversationUseCase: saveConversationUseCase
        )
    }

    @MainActor
    func makeTranscriptionViewModel() -> TranscriptionViewModel { transcriptionViewModel }

    @MainActor
    func makeHistoryViewModel() -> ConversationHistoryViewModel { historyViewModel }
}
