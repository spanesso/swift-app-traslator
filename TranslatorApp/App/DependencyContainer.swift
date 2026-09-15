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
    private let levelMonitor: AudioLevelMonitor
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
    private let openConversationUseCase: OpenConversationUseCase

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
        let ringBuffer = AudioRingBuffer(capacitySeconds: AppleSFSpeechEngine.carryOverCapacitySeconds)
        let sessionCoordinator = AudioSessionCoordinator(telemetry: sink)
        audioSessionCoordinator = sessionCoordinator
        let monitor = AudioLevelMonitor()
        levelMonitor = monitor
        let bufferSink = AudioBufferSink()
        let capture = AudioCaptureSession(telemetry: sink,
                                          requestBox: requestBox,
                                          ringBuffer: ringBuffer,
                                          levelMonitor: monitor,
                                          bufferSink: bufferSink)
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
        let classicEngine = AppleSFSpeechEngine(telemetry: sink,
                                                capture: capture,
                                                requestBox: requestBox,
                                                ringBuffer: ringBuffer,
                                                sessionCoordinator: sessionCoordinator,
                                                levelMonitor: monitor)
        // SpeechAnalyzer migration (2026-09-15): preferred whenever the device supports it and
        // the user has not chosen the classic recogniser; the classic engine takes over if it
        // cannot start, so recording never depends on it.
        let analyzerEngine = AppleSpeechAnalyzerEngine(telemetry: sink,
                                                       capture: capture,
                                                       sessionCoordinator: sessionCoordinator,
                                                       audioSink: bufferSink,
                                                       levelMonitor: monitor)
        let engine = SelectingSpeechEngine(
            preferred: analyzerEngine,
            preferredId: .appleSpeechAnalyzer,
            fallback: classicEngine,
            fallbackId: .legacyAppleSFSpeech,
            usePreferred: {
                EnginePreference.fromUserDefaults().usesSpeechAnalyzer
                    && AppleSpeechAnalyzerEngine.isSupportedOnThisDevice
            },
            telemetry: sink)
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

        // Before the store exists: nothing of a conversation may leave the device automatically,
        // and an iCloud backup of Application Support is exactly that.
        if !BackupExclusion.excludeApplicationSupport() {
            logger.error("[Container] could not exclude Application Support from backups")
        }

        // A store that cannot be opened must not take the app down with it: that crashed before the
        // recovery prompt could ever run, so an unfinished meeting could never be recovered. The
        // app starts with an in-memory stand-in instead; saving reports it, recovery and export
        // keep working (durability audit 2026-09-15, R6).
        var storeIsPersistent = true
        do {
            modelContainer = try ModelContainer(for: ConversationRecord.self,
                                                     SessionQualityRecord.self)
        } catch {
            logger.fault("[Container] conversation store unavailable: \(error.localizedDescription, privacy: .public)")
            storeIsPersistent = false
            do {
                modelContainer = try ModelContainer(for: ConversationRecord.self, SessionQualityRecord.self,
                                                    configurations: ModelConfiguration(isStoredInMemoryOnly: true))
            } catch {
                fatalError("SwiftData could not create even an in-memory store: \(error)")
            }
        }
        // A saved conversation is sealed, as a whole, to a key held by this device's Secure
        // Enclave: only its user can open it again — not the app on its own, not anyone else.
        let sealer = HybridConversationSealer(loadKey: { try ConversationKeychain.loadOrCreateDeviceKey() })
        let convRepo = ConversationRepository(context: modelContainer.mainContext, sealer: sealer,
                                              isPersistent: storeIsPersistent)
        conversationRepository = convRepo
        saveConversationUseCase = SaveConversationUseCase(repository: convRepo, telemetry: sink)
        fetchConversationsUseCase = FetchConversationsUseCase(repository: convRepo)
        openConversationUseCase = OpenConversationUseCase(repository: convRepo)

        // Conversations saved in clear by earlier versions are sealed now. Sealing needs no user
        // interaction, so this never blocks or prompts.
        Task { [logger] in
            do {
                try await convRepo.sealLegacyConversations()
            } catch {
                logger.error("[Container] could not seal earlier conversations: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 010: the transcript is written to disk the moment it exists. Before this it lived only
        // in a ViewModel array, and a force-quit, a background kill or one tap on the record
        // button destroyed the meeting.
        let transcriptJournal = FileTranscriptJournal()
        journal = transcriptJournal

        historyViewModel = ConversationHistoryViewModel(fetchUseCase: fetchConversationsUseCase,
                                                        openUseCase: openConversationUseCase)
        transcriptionViewModel = TranscriptionViewModel(
            transcribeUseCase: transcribeUseCase,
            saveConversationUseCase: saveConversationUseCase,
            downloadCoordinator: coordinator,
            audioSessionCoordinator: sessionCoordinator,
            telemetry: sink,
            journal: transcriptJournal,
            levelMonitor: monitor
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
