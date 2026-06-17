//
//  DependencyContainer.swift
//  TranslatorApp
//
//  Centralized dependency graph. All long-lived instances live here for the app session.

import SwiftUI
import SwiftData
import AVFoundation
import OSLog

final class DependencyContainer {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Container")

    // MARK: - Speech pipeline

    private let speechListener: ContinuousSpeechListener
    private let qualityMetrics: QualityMetricsService
    let downloadCoordinator: BackgroundAssetsCoordinator
    private let correctorService: TranscriptCorrectorService
    private let speechEngine: any SpeechEngineProtocol
    private let speechRepository: SpeechRepositoryProtocol
    private let nlpSegmenter: NLPSegmenterServiceProtocol
    private let transcribeUseCase: TranscribeAudioUseCase

    // MARK: - Persistence

    let modelContainer: ModelContainer
    private let conversationRepository: ConversationRepositoryProtocol
    private let saveConversationUseCase: SaveConversationUseCase
    private let fetchConversationsUseCase: FetchConversationsUseCase

    // MARK: - ViewModels

    private let transcriptionViewModel: TranscriptionViewModel
    private let historyViewModel: ConversationHistoryViewModel

    init() {
        let metrics = QualityMetricsService()
        qualityMetrics = metrics

        let listener = ContinuousSpeechListener(qualityMetrics: metrics)
        speechListener = listener

        let coordinator = BackgroundAssetsCoordinator()
        downloadCoordinator = coordinator

        // Synchronous engine selection via persisted install flag (data-model.md §4.1).
        let preference = EnginePreference.fromUserDefaults()
        let isWhisperInstalled = UserDefaults.standard.bool(forKey: BackgroundAssetsCoordinator.installedKey)

        let engine: any SpeechEngineProtocol
        switch preference {
        case .appleOnly:
            engine = AppleSpeechAnalyzerEngine()
            logger.info("[Container] engine=AppleSpeechAnalyzer (user forced)")
        case .auto, .whisperPreferred:
            if DeviceCapabilities.supportsA17Pro && isWhisperInstalled {
                engine = WhisperKitEngine()
                logger.info("[Container] engine=WhisperKitTurbo")
            } else {
                engine = LegacySFSpeechEngine(listener: listener)
                logger.info("[Container] engine=LegacySFSpeech (fallback)")
            }
        }
        speechEngine = engine

        // Corrector: A17 Pro+ + iOS 26 only
        let corrector: (any TranscriptCorrectorProtocol)?
        if DeviceCapabilities.supportsA17Pro {
            if #available(iOS 26.0, *) {
                corrector = FoundationModelsCorrector()
            } else { corrector = nil }
        } else { corrector = nil }
        correctorService = TranscriptCorrectorService(corrector: corrector)

        let segmenter = NLPSegmenterService(qualityMetrics: metrics)
        nlpSegmenter = segmenter
        speechRepository = SpeechRepository(engine: engine, qualityMetrics: metrics)
        transcribeUseCase = TranscribeAudioUseCase(
            repository: speechRepository, segmenter: nlpSegmenter,
            qualityMetrics: metrics, correctorService: correctorService
        )

        do {
            modelContainer = try ModelContainer(for: ConversationRecord.self,
                                                     SessionQualityRecord.self)
        } catch {
            fatalError("SwiftData container init failed: \(error)")
        }
        let convRepo = ConversationRepository(context: modelContainer.mainContext)
        conversationRepository = convRepo
        saveConversationUseCase = SaveConversationUseCase(repository: convRepo)
        fetchConversationsUseCase = FetchConversationsUseCase(repository: convRepo)

        historyViewModel = ConversationHistoryViewModel(fetchUseCase: fetchConversationsUseCase)
        transcriptionViewModel = TranscriptionViewModel(
            transcribeUseCase: transcribeUseCase,
            saveConversationUseCase: saveConversationUseCase,
            downloadCoordinator: coordinator
        )

        setupInterruptionObserver()
    }

    @MainActor func makeTranscriptionViewModel() -> TranscriptionViewModel { transcriptionViewModel }
    @MainActor func makeHistoryViewModel() -> ConversationHistoryViewModel { historyViewModel }

    // MARK: - SC-010 failure injection (T050)

    private func setupInterruptionObserver() {
        #if os(iOS)
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            guard typeVal == AVAudioSession.InterruptionType.began.rawValue else { return }
            Task { @MainActor [weak self] in
                self?.transcriptionViewModel.handleAudioInterruption()
                self?.logger.warning("[Container] SC-010: audio interrupted → permissionDenied")
            }
        }
        #endif
    }

    // MARK: - SessionQualityRecord pruning (T052)

    func saveAndPruneQualityRecord(_ record: SessionQualityRecord) throws {
        let context = modelContainer.mainContext
        context.insert(record)
        let all = try context.fetch(
            FetchDescriptor<SessionQualityRecord>(
                sortBy: [SortDescriptor(\.startedAt, order: .forward)]
            )
        )
        if all.count > 50 {
            for old in all.prefix(all.count - 50) { context.delete(old) }
        }
        try context.save()
    }
}
