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
    /// Durable record of the meeting in progress (010). The transcript is written here the
    /// moment it exists, so it no longer depends on the process staying alive.
    let journal: any TranscriptJournalProtocol

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

    /// True once the meeting is safely in the history. Prevents a duplicate if the user also
    /// presses Save, and lets the interface say "already saved" instead of implying otherwise.
    var isArchived: Bool = false
    /// Set once if the journal stops accepting writes, so the user is warned exactly once
    /// rather than on every phrase.
    var hasPersistenceFailure: Bool = false
    /// A meeting left behind by a previous run, waiting for the user to recover or discard it.
    var recoverableSession: RecoveredSession?
    /// Raised when starting a new recording would clear content from the screen.
    var pendingNewSessionConfirmation: Bool = false

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
    /// Kept in step with `fragments` instead of recomputed. See `pendingCount`.
    var pendingFragmentCount: Int = 0
    /// Last reconciliation branch reported, so the per-partial telemetry only fires on a change
    /// instead of three times a second for the whole meeting.
    var lastReportedBranch: PrefixBranch?
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
         telemetry: any PipelineTelemetryProtocol,
         journal: any TranscriptJournalProtocol) {
        self.transcribeUseCase = transcribeUseCase
        self.saveConversationUseCase = saveConversationUseCase
        self.downloadCoordinator = downloadCoordinator
        self.audioSessionCoordinator = audioSessionCoordinator
        self.telemetry = telemetry
        self.journal = journal
        subscribeToDownloadState()
        subscribeToAudioEvents()
    }

    // MARK: - Recovery (010 US2)

    /// Looks for a meeting left behind by a previous run. Called when the interface appears.
    func checkForRecoverableSession() async {
        guard fragments.isEmpty, !isRecording else { return }
        guard let recovered = await journal.pendingSession(), !recovered.isEmpty else { return }
        recoverableSession = recovered
        logger.notice("[ViewModel] found a recoverable session with \(recovered.fragments.count) fragment(s)")
    }

    /// Brings the recovered meeting back on screen. It behaves like any other finished session:
    /// it can be saved and exported, and its journal stays on disk until it is.
    func recoverPendingSession() {
        guard let recovered = recoverableSession else { return }
        fragments = recovered.fragments
        fragmentKeys = Set(recovered.fragments.map { Self.dedupKey($0.sourceText) })
        nextFragmentId = (recovered.fragments.map(\.id).max() ?? -1) + 1
        sessionId = recovered.sessionId
        isArchived = false
        currentBuffer = ""
        recoverableSession = nil
        logger.info("[ViewModel] recovered session restored to screen")
    }

    /// Throws the recovered meeting away. Only ever reached through an explicit confirmation in
    /// the interface (FR-012).
    func discardPendingSession() {
        recoverableSession = nil
        Task { [journal] in await journal.discard() }
        logger.notice("[ViewModel] recovered session discarded by the user")
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

    /// Entry point for the record button.
    ///
    /// Starting a new meeting with content on screen used to wipe it with no warning — one tap,
    /// no confirmation, no recovery. Now it asks (010 FR-019). With automatic archiving the
    /// previous meeting is already safe, so this is a safety net rather than the last line of
    /// defence, but the user still deserves to know their screen is about to be cleared.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else if fragments.isEmpty {
            startRecording()
        } else {
            pendingNewSessionConfirmation = true
        }
    }

    /// Called after the user confirms they want to start over.
    func confirmStartNewSession() {
        pendingNewSessionConfirmation = false
        startRecording()
    }

    func cancelStartNewSession() {
        pendingNewSessionConfirmation = false
    }

    /// Message for that confirmation, honest about whether the previous meeting is safe.
    var newSessionConfirmationMessage: String {
        isArchived
            ? "The previous meeting is saved in your history. Starting a new recording will clear the screen."
            : "The previous meeting has NOT been saved yet. Starting a new recording will discard it."
    }

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
