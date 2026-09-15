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
    /// The meeting's audio while the user has not decided yet (TranscriptionViewModel+Audio.swift).
    /// Recorded for diarisation and accuracy measurement, shredded when they save or discard.
    let meetingAudio: any MeetingAudioProtocol
    /// Live input level. Reading it is how the user finds out, DURING the meeting, that a quiet
    /// speaker is not reaching the microphone — instead of discovering the gap afterwards.
    let levelMonitor: AudioLevelMonitor

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

    /// Identity of the CURRENT request stream. The interface keys its translation task on this,
    /// not on `isRecording`.
    ///
    /// A manual restart replaces the stream while the session stays recording, so `isRecording`
    /// never changes value: the old consumer ended with the old stream and no new one was ever
    /// created. Every phrase after that point was queued into a stream nobody was reading and
    /// kept its spinner for the rest of the meeting, with no error anywhere.
    var translationStreamId: UUID?

    /// Incremented once per recording session. Shutdown is asynchronous, so its tail can land
    /// after the user has already started the next meeting; without this it closed the NEW
    /// session's request stream. Anything queued behind an `await` re-checks this before
    /// touching session state.
    var sessionEpoch: Int = 0

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
    /// Raised when the user asks to discard a meeting that has not been saved.
    var pendingDiscardConfirmation: Bool = false
    /// Raised when the user asks to discard the unfinished meeting found at launch.
    var pendingRecoveryDiscardConfirmation: Bool = false

    /// The fragment whose translation has been in flight long enough that something is wrong.
    /// The queue is deliberately serial (concurrent calls on one `TranslationSession` are not
    /// documented as safe), so a single stuck call stops the Spanish pane for good. Nothing is
    /// lost — the English is journaled and the fragments resolve as unavailable at stop — but
    /// without this the user just watches one pane stop growing and cannot tell why.
    var stalledTranslationId: Int?
    var isTranslationStalled: Bool { stalledTranslationId != nil }

    /// What the microphone is picking up right now, refreshed while recording.
    var inputLevel: AudioLevelMonitor.Reading = .silent

    /// Kept as a derived value so existing views and `onChange` observers are unaffected.
    var isRecording: Bool { sessionState.isRecording }
    var isSuspended: Bool { sessionState.isSuspended }
    var suspensionReason: AudioInterruptionReason? { sessionState.suspensionReason }
    /// Only once fully stopped: during `.stopping` the last phrase and translations are still
    /// arriving, and saving then sealed an incomplete meeting (durability audit 2026-09-15).
    var canSave: Bool { sessionState == .idle && !fragments.isEmpty }

    // MARK: - Private state

    var translationContinuation: AsyncStream<TranslationRequest>.Continuation?
    var transcriptionTask: Task<Void, Never>?
    private var downloadStateTask: Task<Void, Never>?
    private var audioEventTask: Task<Void, Never>?
    /// Recent phrases only, not the whole meeting: a phrase said again later is not a duplicate
    /// (research 2026-09-15, P2).
    var recentPhrases = RecentPhraseFilter()
    /// True while `restartListening` replaces the pipeline, so the old consumer ending on purpose
    /// is not mistaken for the session ending.
    var isRestartingListening = false
    /// Kept in step with `fragments` instead of recomputed. See `pendingCount`.
    var pendingFragmentCount: Int = 0
    /// Last reconciliation branch reported, so the per-partial telemetry only fires on a change
    /// instead of three times a second for the whole meeting.
    var lastReportedBranch: PrefixBranch?
    var translationWatchdog: Task<Void, Never>?
    /// Draft journaling of the words not committed yet (TranscriptionViewModel+Draft.swift).
    var draftTask: Task<Void, Never>?
    var lastDraftText: String?
    var lastDraftAt: ContinuousClock.Instant?
    var levelPollTask: Task<Void, Never>?
    /// Well above anything legitimate: field telemetry showed a median of ~79 ms, a ~1.3 s cold
    /// start, and a single 3.9 s outlier at shutdown. Ten seconds only fires when it is stuck.
    nonisolated static var translationStallThresholdMs: Int { 10_000 }
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
         journal: any TranscriptJournalProtocol,
         meetingAudio: any MeetingAudioProtocol,
         levelMonitor: AudioLevelMonitor) {
        self.transcribeUseCase = transcribeUseCase
        self.saveConversationUseCase = saveConversationUseCase
        self.downloadCoordinator = downloadCoordinator
        self.audioSessionCoordinator = audioSessionCoordinator
        self.telemetry = telemetry
        self.journal = journal
        self.meetingAudio = meetingAudio
        self.levelMonitor = levelMonitor
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

    /// Entry point for the record button.
    ///
    /// Starting a new meeting with content on screen used to wipe it with no warning — one tap,
    /// no confirmation, no recovery. Now it asks (010 FR-019), and since 2026-09-15 a finished
    /// meeting is never saved on its own: the question is whether to save or discard it.
    func toggleRecording() {
        if isRecording {
            stopRecording()
        } else if sessionState == .stopping {
            // The last meeting is still delivering its last phrase. Starting now left its consumer
            // alive: that phrase landed in the new meeting, and the old stream closing stopped the
            // NEW recording (durability audit 2026-09-15).
            return
        } else if recoverableSession != nil {
            // The recovery prompt is on screen and has to be answered first.
            return
        } else if fragments.isEmpty {
            startRecordingUnlessAMeetingIsPending()
        } else {
            pendingNewSessionConfirmation = true
        }
    }

    // Answering that confirmation is a decision about the meeting that just ended, so it lives with
    // the others in TranscriptionViewModel+Archive.swift.
}
