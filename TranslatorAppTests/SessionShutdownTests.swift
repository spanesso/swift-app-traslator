//
//  SessionShutdownTests.swift
//  TranslatorAppTests
//
//  Text the ViewModel threw away on its own (research 2026-09-15, findings P1 and P2):
//  the phrase still pending when the user pressed stop, and any phrase that had already been
//  said once earlier in the meeting. Both tests fail on the code as it was diagnosed.
//

import XCTest
@testable import TranslatorApp

// MARK: - Fakes

/// Stands in for the recogniser. Stopping finishes the stream, as the real engine does.
final class FakeSpeechRepository: SpeechRepositoryProtocol, @unchecked Sendable {
    private(set) var continuation: AsyncStream<SpeechSegment>.Continuation?
    /// False simulates a recogniser that never closes its stream when asked to stop.
    var finishesOnStop = true

    func startTranscription() async throws -> AsyncStream<SpeechSegment> {
        let (stream, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        self.continuation = continuation
        return stream
    }

    func stopTranscription() async {
        if finishesOnStop { continuation?.finish() }
    }
}

final class FakeAudioSessionCoordinator: AudioSessionCoordinatorProtocol {
    private let events = AsyncStream.makeStream(of: AudioSessionEvent.self)

    func eventStream() -> AsyncStream<AudioSessionEvent> { events.stream }
    func setSessionId(_ id: String) async {}
    func activate() async throws {}
    func deactivate() async {}
    func startObserving() async {}
    func stopObserving() async {}
    func attemptReactivation() async -> Bool { true }
    func noteSuspended(reason: AudioInterruptionReason) async {}
    func noteResumed() async {}
}

actor InMemoryTranscriptJournal: TranscriptJournalProtocol {
    private(set) var entries: [TranscriptJournalEntry] = []
    private(set) var calls: [String] = []
    private var pending: RecoveredSession?

    func setPending(_ session: RecoveredSession?) { pending = session }

    func beginSession(id: String) async throws { calls.append("begin") }
    func record(_ entry: TranscriptJournalEntry) async throws { entries.append(entry) }
    func pendingSession() async -> RecoveredSession? { pending }
    func hasPendingSession() async -> Bool { pending != nil }
    func setAsideUnreadable() async { calls.append("setAside") }
    func discard() async { calls.append("discard"); entries.removeAll() }
}

final class FakeConversationRepository: ConversationRepositoryProtocol, @unchecked Sendable {
    private(set) var saved: [ConversationEntity] = []
    func save(_ conversation: ConversationEntity) async throws { saved.append(conversation) }
    func fetchSummaries() async throws -> [ConversationSummary] {
        saved.map { ConversationSummary(id: $0.id, savedAt: $0.savedAt) }
    }
    func open(id: UUID, reason: String) async throws -> ConversationEntity {
        guard let conversation = saved.first(where: { $0.id == id }) else { throw ConversationStoreError.notFound }
        return conversation
    }
    func sealLegacyConversations() async throws -> Int { 0 }
}

// MARK: - Tests

@MainActor
final class SessionShutdownTests: XCTestCase {

    private func makeViewModel(repository: FakeSpeechRepository,
                               journal: InMemoryTranscriptJournal = InMemoryTranscriptJournal(),
                               conversations: FakeConversationRepository = FakeConversationRepository())
        -> TranscriptionViewModel {
        let telemetry = NoopPipelineTelemetry()
        let metrics = QualityMetricsService()
        let useCase = TranscribeAudioUseCase(
            repository: repository,
            segmenter: NLPSegmenterService(qualityMetrics: metrics, telemetry: telemetry),
            qualityMetrics: metrics,
            correctorService: TranscriptCorrectorService(corrector: nil))
        return TranscriptionViewModel(
            transcribeUseCase: useCase,
            saveConversationUseCase: SaveConversationUseCase(repository: conversations,
                                                             telemetry: telemetry),
            downloadCoordinator: BackgroundAssetsCoordinator(),
            audioSessionCoordinator: FakeAudioSessionCoordinator(),
            telemetry: telemetry,
            journal: journal,
            levelMonitor: AudioLevelMonitor())
    }

    /// Polls `condition` on the main actor until it holds or the time runs out.
    private func waitUntil(timeoutMs: Int, _ condition: () -> Bool) async -> Bool {
        let deadline = MonotonicClock.now().advanced(by: .milliseconds(timeoutMs))
        while MonotonicClock.now() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    // MARK: - P1: stopping must not lose the phrase in progress

    /// The speaker is mid-phrase and the user presses stop. The consumer of the segmenter was
    /// cancelled BEFORE the pipeline was asked to flush, so the trailing phrase was emitted into
    /// a stream nobody was reading. Every meeting lost its last words this way.
    func testPhraseStillPendingWhenTheUserStopsIsKept() async {
        let repository = FakeSpeechRepository()
        let viewModel = makeViewModel(repository: repository)

        viewModel.startRecording()
        let started = await waitUntil(timeoutMs: 1_000) { repository.continuation != nil }
        XCTAssertTrue(started, "fixture: transcription never started")

        repository.continuation?.yield(SpeechSegment(text: "we need to migrate the courses to the new packet",
                                                     isFinal: false, confidence: 0.9))
        // Well inside the 700 ms stability delay: the phrase is still pending when stop arrives.
        try? await Task.sleep(nanoseconds: 200_000_000)
        viewModel.stopRecording()

        let kept = await waitUntil(timeoutMs: 2_500) {
            viewModel.fragments.contains { $0.sourceText.contains("migrate the courses") }
        }
        XCTAssertTrue(kept, "the phrase in progress was lost at stop: \(viewModel.fragments.map(\.sourceText))")
    }

    // MARK: - Only the user decides what happens to a finished meeting (2026-09-15)

    /// Stopping used to archive the meeting on its own. The user now chooses to save it, share
    /// it or discard it — and until they do, nothing is saved AND nothing is thrown away: the
    /// meeting stays on screen and its journal stays on disk.
    func testStoppingNeverSavesOrDiscardsWithoutTheUserChoosing() async {
        let repository = FakeSpeechRepository()
        let conversations = FakeConversationRepository()
        let journal = InMemoryTranscriptJournal()
        let viewModel = makeViewModel(repository: repository, journal: journal, conversations: conversations)

        viewModel.startRecording()
        _ = await waitUntil(timeoutMs: 1_000) { repository.continuation != nil }
        repository.continuation?.yield(SpeechSegment(text: "the budget for next quarter is approved.",
                                                     isFinal: false, confidence: 0.9))
        let committed = await waitUntil(timeoutMs: 1_500) { !viewModel.fragments.isEmpty }
        XCTAssertTrue(committed, "fixture: the phrase must be committed before stopping")

        viewModel.stopRecording()
        let idle = await waitUntil(timeoutMs: 6_000) { viewModel.sessionState == .idle }
        XCTAssertTrue(idle, "fixture: the session never finished stopping")
        try? await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertTrue(conversations.saved.isEmpty, "the meeting was saved without the user choosing to")
        XCTAssertFalse(viewModel.fragments.isEmpty, "the meeting must stay on screen until the user decides")
        let calls = await journal.calls
        XCTAssertFalse(calls.contains("discard"), "the journal is the only copy until the user decides: \(calls)")
    }

    /// Exporting does not depend on saving.
    func testAnUnsavedMeetingCanBeShared() {
        let viewModel = makeViewModel(repository: FakeSpeechRepository())
        viewModel.commitPhrase(SegmentedPhrase(text: "we will review the offer tomorrow"))

        XCTAssertTrue(viewModel.hasUnsavedMeeting)
        XCTAssertTrue(viewModel.canSave, "the actions must be offered")
        XCTAssertTrue(viewModel.exportText.contains("we will review the offer tomorrow"))
    }

    /// Saving stores the meeting once, and only then lets go of the journal.
    func testSavingStoresTheMeetingAndOnlyThenReleasesTheJournal() async {
        let journal = InMemoryTranscriptJournal()
        let conversations = FakeConversationRepository()
        let viewModel = makeViewModel(repository: FakeSpeechRepository(), journal: journal,
                                      conversations: conversations)
        viewModel.commitPhrase(SegmentedPhrase(text: "we will review the offer tomorrow"))

        let saved = await viewModel.persistMeeting()

        XCTAssertTrue(saved)
        XCTAssertEqual(conversations.saved.count, 1)
        XCTAssertTrue(viewModel.isArchived)
        XCTAssertFalse(viewModel.hasUnsavedMeeting)
        let calls = await journal.calls
        XCTAssertTrue(calls.contains("discard"))
    }

    /// Asking to discard changes nothing; only the confirmation does.
    func testDiscardingNeedsConfirmation() async {
        let journal = InMemoryTranscriptJournal()
        let viewModel = makeViewModel(repository: FakeSpeechRepository(), journal: journal)
        viewModel.commitPhrase(SegmentedPhrase(text: "we will review the offer tomorrow"))

        viewModel.requestDiscard()
        XCTAssertTrue(viewModel.pendingDiscardConfirmation)
        XCTAssertEqual(viewModel.fragments.count, 1, "asking is not discarding")
        var calls = await journal.calls
        XCTAssertFalse(calls.contains("discard"))

        viewModel.discardConversation()
        XCTAssertTrue(viewModel.fragments.isEmpty)
        let released = await waitUntilAsync(timeoutMs: 1_000) { await journal.calls.contains("discard") }
        XCTAssertTrue(released, "a discarded meeting must not be offered for recovery")
        calls = await journal.calls
        XCTAssertEqual(calls.filter { $0 == "discard" }.count, 1)
    }

    // MARK: - Killed mid-phrase (out of memory, 2026-09-15)

    /// The words not yet committed lived only in memory. An out-of-memory termination gives no
    /// warning and runs no code, so they must already be on disk when it happens.
    func testTextNotYetCommittedIsJournaledWhileRecording() async {
        let repository = FakeSpeechRepository()
        let journal = InMemoryTranscriptJournal()
        let viewModel = makeViewModel(repository: repository, journal: journal)

        viewModel.startRecording()
        _ = await waitUntil(timeoutMs: 1_000) { repository.continuation != nil }
        viewModel.applyRawSegment(SpeechSegment(text: "we were discussing the budget for next",
                                                isFinal: false, confidence: 0.9))

        let written = await waitUntilAsync(timeoutMs: 1_500) {
            await journal.entries.contains {
                $0.kind.rawValue == "draft" && ($0.sourceText ?? "").contains("budget for next")
            }
        }
        XCTAssertTrue(written, "the phrase in progress is not on disk: an out-of-memory kill would lose it")
        viewModel.stopRecording()
    }

    // MARK: - Loss paths found by the durability audit (2026-09-15)

    /// Record while the previous meeting was still stopping started a new session with the old
    /// consumer alive: the old meeting's last phrase landed in the new one, and the old stream
    /// ending then stopped the NEW recording.
    func testRecordIsIgnoredWhileTheLastMeetingIsStillStopping() {
        let viewModel = makeViewModel(repository: FakeSpeechRepository())
        viewModel.commitPhrase(SegmentedPhrase(text: "the last phrase of the meeting"))
        viewModel.sessionState = .stopping

        viewModel.toggleRecording()

        XCTAssertFalse(viewModel.pendingNewSessionConfirmation, "a new meeting was offered before the last one finished stopping")
        XCTAssertEqual(viewModel.sessionState, .stopping)
    }

    /// Save during `.stopping` sealed the meeting without its last phrase, then the late phrase
    /// recreated the journal as a ghost.
    func testSaveIsNotOfferedUntilTheMeetingHasFinishedStopping() {
        let viewModel = makeViewModel(repository: FakeSpeechRepository())
        viewModel.commitPhrase(SegmentedPhrase(text: "the last phrase of the meeting"))

        viewModel.sessionState = .stopping
        XCTAssertFalse(viewModel.canSave, "saving before the last phrase arrives saves an incomplete meeting")
        viewModel.sessionState = .idle
        XCTAssertTrue(viewModel.canSave)
    }

    /// Words still on screen when the pipeline closed without committing them used to vanish
    /// with the stop.
    func testWordsStillOnScreenAtStopBecomeAPhrase() async {
        let repository = FakeSpeechRepository()
        repository.finishesOnStop = false
        let viewModel = makeViewModel(repository: repository)

        viewModel.startRecording()
        _ = await waitUntil(timeoutMs: 1_000) { repository.continuation != nil }
        viewModel.applyRawSegment(SpeechSegment(text: "we were about to decide the", isFinal: false, confidence: 0.9))
        viewModel.stopRecording()

        let kept = await waitUntil(timeoutMs: 4_500) {
            viewModel.fragments.contains { $0.sourceText.contains("about to decide") }
        }
        XCTAssertTrue(kept, "the words on screen at stop were lost: \(viewModel.fragments.map(\.sourceText))")
    }

    /// Translation is on-device and regenerable. A phrase recovered without its Spanish used to
    /// stay "unavailable" for good.
    func testRecoveredPhrasesWithoutTranslationAreTranslatedAgain() async {
        let journal = InMemoryTranscriptJournal()
        await journal.setPending(RecoveredSession(sessionId: "OLD1", fragments: [
            ConversationFragment(id: 0, sourceText: "we approved the budget",
                                 translation: .translated("aprobamos el presupuesto"), sourceConfidence: 0.9),
            ConversationFragment(id: 1, sourceText: "next we review hiring",
                                 translation: .unavailable(.timedOut), sourceConfidence: 0.9)
        ], startedAtEpochMs: 1))
        let viewModel = makeViewModel(repository: FakeSpeechRepository(), journal: journal)

        await viewModel.checkForRecoverableSession()
        viewModel.recoverPendingSession()

        XCTAssertEqual(viewModel.fragments.first?.translation, .translated("aprobamos el presupuesto"))
        XCTAssertEqual(viewModel.fragments.last?.isPending, true, "the missing translation must be requested again")
        XCTAssertNotNil(viewModel.translationStreamId, "something must be there to translate it")
    }

    // MARK: - P2: saying something twice in a meeting is not a duplicate

    /// The duplicate filter remembered every phrase for the whole meeting, so the second "Okay."
    /// of a meeting was dropped before it was journaled.
    func testShortReplyRepeatedLaterInTheMeetingIsKept() {
        let viewModel = makeViewModel(repository: FakeSpeechRepository())

        viewModel.commitPhrase(SegmentedPhrase(text: "Okay."))
        viewModel.commitPhrase(SegmentedPhrase(text: "Let us continue with the budget."))
        viewModel.commitPhrase(SegmentedPhrase(text: "Okay."))

        XCTAssertEqual(viewModel.fragments.map(\.sourceText),
                       ["Okay.", "Let us continue with the budget.", "Okay."])
    }

    func testLongPhraseRepeatedAfterOtherPhrasesIsKept() {
        let viewModel = makeViewModel(repository: FakeSpeechRepository())

        viewModel.commitPhrase(SegmentedPhrase(text: "thank you very much"))
        viewModel.commitPhrase(SegmentedPhrase(text: "the first item is the budget"))
        viewModel.commitPhrase(SegmentedPhrase(text: "the second item is hiring"))
        viewModel.commitPhrase(SegmentedPhrase(text: "and the third one is travel"))
        viewModel.commitPhrase(SegmentedPhrase(text: "the fourth one is the offsite"))
        viewModel.commitPhrase(SegmentedPhrase(text: "thank you very much"))

        XCTAssertEqual(viewModel.fragments.count, 6,
                       "a phrase said again later is not a duplicate: \(viewModel.fragments.map(\.sourceText))")
    }

    // MARK: - P9: a new meeting must never be written into the previous one's journal

    /// The user confirmed that the unsaved previous meeting may be discarded. Its journal used to
    /// stay on disk, `beginSession` refused to open over it, and every phrase of the NEW meeting
    /// was then appended into the OLD file — recovery mixed the two meetings together.
    func testConfirmedNewMeetingDiscardsTheUnsavedJournalBeforeOpeningItsOwn() async {
        let journal = InMemoryTranscriptJournal()
        let viewModel = makeViewModel(repository: FakeSpeechRepository(), journal: journal)
        viewModel.commitPhrase(SegmentedPhrase(text: "a meeting that was never saved"))
        XCTAssertFalse(viewModel.isArchived, "fixture: the previous meeting must be unsaved")

        viewModel.confirmStartNewSession()
        let opened = await waitUntilAsync(timeoutMs: 1_000) { await journal.calls.contains("begin") }
        XCTAssertTrue(opened, "fixture: the new journal was never opened")

        let calls = await journal.calls
        XCTAssertEqual(calls, ["discard", "begin"],
                       "the old journal must be discarded before the new one is opened: \(calls)")
        viewModel.stopRecording()
    }

    private func waitUntilAsync(timeoutMs: Int, _ condition: () async -> Bool) async -> Bool {
        let deadline = MonotonicClock.now().advanced(by: .milliseconds(timeoutMs))
        while MonotonicClock.now() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return await condition()
    }

    /// The guard the filter exists for must survive: the same sentence delivered twice in a row
    /// by the pipeline is still one fragment.
    func testImmediateDuplicateSentenceIsStillDropped() {
        let viewModel = makeViewModel(repository: FakeSpeechRepository())

        viewModel.commitPhrase(SegmentedPhrase(text: "we will ship the release on friday."))
        viewModel.commitPhrase(SegmentedPhrase(text: "We will ship the release on Friday"))

        XCTAssertEqual(viewModel.fragments.count, 1)
    }
}
