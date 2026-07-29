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

    // MARK: - Cross-cutting

    private let telemetry: any PipelineTelemetryProtocol

    // MARK: - Speech pipeline

    private let qualityMetrics: QualityMetricsService
    let downloadCoordinator: BackgroundAssetsCoordinator
    private let correctorService: TranscriptCorrectorService
    private let audioSessionCoordinator: AudioSessionCoordinator
    private let audioCapture: AudioCaptureSession
    private let speechEngine: any SpeechEngineProtocol
    private let speechRepository: SpeechRepositoryProtocol
    private let nlpSegmenter: NLPSegmenterServiceProtocol
    private let transcribeUseCase: TranscribeAudioUseCase

    // MARK: - Persistence

    let modelContainer: ModelContainer
    private let journal: any TranscriptJournalProtocol
    private let conversationRepository: ConversationRepositoryProtocol
    private let saveConversationUseCase: SaveConversationUseCase
    private let fetchConversationsUseCase: FetchConversationsUseCase

    // MARK: - ViewModels

    private let transcriptionViewModel: TranscriptionViewModel
    private let historyViewModel: ConversationHistoryViewModel

    init() {
        // Built first: everything downstream reports through it.
        let sink = PipelineTelemetry()
        telemetry = sink

        let metrics = QualityMetricsService()
        qualityMetrics = metrics

        let coordinator = BackgroundAssetsCoordinator()
        downloadCoordinator = coordinator

        // MARK: Audio ownership
        // One owner for the audio session, one for the engine and its tap. Previously each
        // speech engine configured AVAudioSession itself — inconsistently — and a loose
        // observer in this file handled only the start of an interruption.
        let requestBox = RecognitionRequestBox()
        let ringBuffer = AudioRingBuffer(capacitySeconds: 1.5)
        let sessionCoordinator = AudioSessionCoordinator(telemetry: sink)
        audioSessionCoordinator = sessionCoordinator
        let capture = AudioCaptureSession(telemetry: sink,
                                          requestBox: requestBox,
                                          ringBuffer: ringBuffer)
        audioCapture = capture

        // MARK: Engine selection (008 decision Q1)
        // The local WhisperKit engine is withdrawn in this phase: it re-processed the whole
        // accumulated session on every 2-second window (unbounded cost) and marked every result
        // as a hypothesis, so nothing ever reached the translation layer. Its redesign belongs
        // to a later phase. `whisperPreferred` is retained as a stored value — users have it
        // saved — but resolves to the Apple route.
        let preference = EnginePreference.fromUserDefaults()
        if !preference.isAvailable {
            logger.notice("[Container] preference=\(preference.rawValue, privacy: .public) is withdrawn in this build; using the Apple route")
        }
        let engine = AppleSFSpeechEngine(telemetry: sink,
                                         capture: capture,
                                         requestBox: requestBox,
                                         ringBuffer: ringBuffer,
                                         sessionCoordinator: sessionCoordinator)
        speechEngine = engine
        // Canonical, unambiguous engine-selection line for on-device diagnostics.
        logger.info("[Container] engine=\(engine.engineId.rawValue, privacy: .public)")

        // Corrector: A17 Pro+ only (iOS 26 is the deployment target, so no availability branch).
        let corrector: (any TranscriptCorrectorProtocol)? =
            DeviceCapabilities.supportsA17Pro ? FoundationModelsCorrector() : nil
        correctorService = TranscriptCorrectorService(corrector: corrector)

        let segmenter = NLPSegmenterService(qualityMetrics: metrics, telemetry: sink)
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
        saveConversationUseCase = SaveConversationUseCase(repository: convRepo, telemetry: sink)
        fetchConversationsUseCase = FetchConversationsUseCase(repository: convRepo)

        // 010: the transcript is written to disk the moment it exists. Before this it lived only
        // in a ViewModel array, and a force-quit, a background kill or one tap on the record
        // button destroyed the meeting.
        let transcriptJournal = FileTranscriptJournal()
        journal = transcriptJournal

        historyViewModel = ConversationHistoryViewModel(fetchUseCase: fetchConversationsUseCase)
        transcriptionViewModel = TranscriptionViewModel(
            transcribeUseCase: transcribeUseCase,
            saveConversationUseCase: saveConversationUseCase,
            downloadCoordinator: coordinator,
            audioSessionCoordinator: sessionCoordinator,
            telemetry: sink,
            journal: transcriptJournal
        )
    }

    @MainActor func makeTranscriptionViewModel() -> TranscriptionViewModel { transcriptionViewModel }
    @MainActor func makeHistoryViewModel() -> ConversationHistoryViewModel { historyViewModel }

    /// Telemetry sink for the app shell (scene-phase reporting).
    func makeTelemetry() -> any PipelineTelemetryProtocol { telemetry }

    // MARK: - SessionQualityRecord pruning

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
