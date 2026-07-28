//
//  TranscriptionViewModel.swift
//  TranslatorApp
//

import SwiftUI
import OSLog

/// A phrase queued for translation. Carries the fragment id so the result can be routed back to
/// the exact fragment it belongs to — previously the two sides were only related by arrival
/// order, which is what let the English and Spanish lists drift apart.
struct TranslationRequest: Sendable {
    let fragmentId: Int
    let text: String
    let sourceConfidence: Float
}

@MainActor
@Observable
final class TranscriptionViewModel {
    let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "ViewModel")
    let transcribeUseCase: TranscribeAudioUseCase
    let saveConversationUseCase: SaveConversationUseCase
    let downloadCoordinator: BackgroundAssetsCoordinator
    private let audioSessionCoordinator: any AudioSessionCoordinatorProtocol
    let telemetry: any PipelineTelemetryProtocol

    // MARK: - State

    var currentBuffer: String = ""
    var hasError: Bool = false
    var errorMessage: String?
    var translatorState: TranslatorState = .idle
    var modelInstallState: ModelInstallState = .notRequested
    var enginePreference: EnginePreference = .fromUserDefaults()

    /// The single ordered list of conversation fragments. Replaces the two parallel arrays whose
    /// counts nothing kept in step.
    var fragments: [ConversationFragment] = []

    /// Lifecycle of the user-visible recording session. An interruption moves this to
    /// `.suspended`, NOT to `.idle` — that distinction is the whole of US5.
    var sessionState: RecordingSessionState = .idle

    var translationRequests: AsyncStream<TranslationRequest>?
    var isSaving: Bool = false
    var savedSuccessfully: Bool = false
    var latestSegmentConfidence: Float = 1.0

    /// Kept as a derived value so existing views and `onChange` observers are unaffected.
    var isRecording: Bool { sessionState.isRecording }
    var isSuspended: Bool { sessionState.isSuspended }
    var suspensionReason: AudioInterruptionReason? { sessionState.suspensionReason }
    var canSave: Bool { !isRecording && !fragments.isEmpty }

    // MARK: - Private state

    var translationContinuation: AsyncStream<TranslationRequest>.Continuation?
    var transcriptionTask: Task<Void, Never>?
    private var downloadStateTask: Task<Void, Never>?
    private var audioEventTask: Task<Void, Never>?
    var fragmentKeys: Set<String> = []
    var nextFragmentId: Int = 0
    var sessionId = "----"

    /// Pure, unit-testable reconciliation of the live tail. Its baseline is what has been
    /// committed since the CURRENT recognition session began — not the whole meeting, which is
    /// what used to freeze the English pane a minute in.
    var reconciler = LiveTailReconciler()
    var lastSeenGeneration = 0

    // MARK: - Init

    init(transcribeUseCase: TranscribeAudioUseCase,
         saveConversationUseCase: SaveConversationUseCase,
         downloadCoordinator: BackgroundAssetsCoordinator,
         audioSessionCoordinator: any AudioSessionCoordinatorProtocol,
         telemetry: any PipelineTelemetryProtocol) {
        self.transcribeUseCase = transcribeUseCase
        self.saveConversationUseCase = saveConversationUseCase
        self.downloadCoordinator = downloadCoordinator
        self.audioSessionCoordinator = audioSessionCoordinator
        self.telemetry = telemetry
        subscribeToDownloadState()
        subscribeToAudioEvents()
    }

    // MARK: - Subscriptions

    private func subscribeToDownloadState() {
        downloadStateTask = Task { [weak self] in
            guard let self else { return }
            for await state in await downloadCoordinator.stateStream() {
                self.modelInstallState = state
            }
        }
    }

    /// Drives the UI from audio-system events. The recovery itself happens in the engine; this
    /// only makes what is happening visible and honest.
    private func subscribeToAudioEvents() {
        let events = audioSessionCoordinator.eventStream()
        audioEventTask = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                switch event {
                case .interrupted(let reason):
                    self.enterSuspended(reason: reason)
                case .captureNeedsRebuild:
                    // Deliberately NOT a user-visible pause. Rebuilding the tap after a device
                    // change is an internal, sub-second operation that the engine handles; if it
                    // fails, the engine suspends and the coordinator publishes `.interrupted`,
                    // which is what reaches the banner. Surfacing every rebuild announced a
                    // pause that had not happened.
                    break
                case .resumed:
                    self.leaveSuspended()
                case .giveUp(let afterMs):
                    self.abandonAfterInterruption(afterMs: afterMs)
                }
            }
        }
    }

    func acceptModelDownload() { Task { await downloadCoordinator.acceptDownload() } }
    func declineModelDownload() { Task { await downloadCoordinator.declineDownload() } }

    func saveEnginePreference(_ pref: EnginePreference) {
        enginePreference = pref
        pref.saveToUserDefaults()
    }

    // MARK: - Recording control

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    /// Manual restart. The 300 ms sleep this used to contain is gone: it deterministically threw
    /// away a third of a second of audio with the engine already stopped, and the recogniser
    /// rotation path (which loses nothing) does the same job.
    func restartListening() {
        guard isRecording else { return }
        transcriptionTask?.cancel(); transcriptionTask = nil
        translationContinuation?.finish(); translationContinuation = nil; translationRequests = nil
        Task { [weak self] in
            guard let self else { return }
            await self.transcribeUseCase.stop()
            self.startRecording(preservingSession: true)
        }
    }
}
