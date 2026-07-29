//
//  TranscriptJournalTests.swift
//  TranslatorAppTests
//
//  Durability and recovery (010-transcript-durability).
//
//  The transcript is the product. These tests exist because it used to live only in a ViewModel
//  array, where a force-quit, a background kill or one tap on the record button destroyed it.
//

import XCTest
@testable import TranslatorApp

final class TranscriptJournalTests: XCTestCase {

    private var journal: FileTranscriptJournal!

    override func setUp() async throws {
        journal = FileTranscriptJournal()
        await journal.discard()   // start from a known-empty state
    }

    override func tearDown() async throws {
        await journal.discard()
        journal = nil
    }

    private func fragment(_ id: Int, _ text: String) -> ConversationFragment {
        ConversationFragment(id: id, sourceText: text, translation: .pending, sourceConfidence: 0.9)
    }

    private func journalURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                  in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        return support
            .appendingPathComponent("LiveTranscript", isDirectory: true)
            .appendingPathComponent("session.jsonl")
    }

    // MARK: - Nothing to recover

    func testNoPendingSessionWhenNothingWasWritten() async throws {
        let hasPending = await journal.hasPendingSession()
        XCTAssertFalse(hasPending)
        let recovered = await journal.pendingSession()
        XCTAssertNil(recovered, "an empty journal must not produce a recovery prompt")
    }

    // MARK: - The core promise

    /// Whatever was written is still there for the next launch. This is the whole feature.
    func testWrittenPhrasesSurviveAndRecoverInOrder() async throws {
        try await journal.beginSession(id: "S1")
        for index in 0..<10 {
            try await journal.record(.source(fragment(index, "phrase \(index)"),
                                             sessionId: "S1", epochMs: 1_000 + index))
        }

        // A brand-new instance: nothing carried over in memory, exactly like a fresh launch.
        let afterRelaunch = FileTranscriptJournal()
        let recovered = await afterRelaunch.pendingSession()

        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered?.fragments.count, 10)
        XCTAssertEqual(recovered?.fragments.map(\.sourceText),
                       (0..<10).map { "phrase \($0)" })
        XCTAssertEqual(recovered?.sessionId, "S1")
    }

    func testTranslationsAreRecoveredToo() async throws {
        try await journal.beginSession(id: "S2")
        try await journal.record(.source(fragment(0, "hello"), sessionId: "S2", epochMs: 1))
        let entry = try XCTUnwrap(TranscriptJournalEntry.translation(
            fragmentId: 0, outcome: .translated("hola"), sessionId: "S2", epochMs: 2))
        try await journal.record(entry)

        let recovered = await FileTranscriptJournal().pendingSession()
        XCTAssertEqual(recovered?.fragments.first?.translation, .translated("hola"))
    }

    /// A failed translation must recover as a failure, not as a blank waiting to be misread as
    /// a missing phrase.
    func testUnavailableTranslationsRecoverAsUnavailable() async throws {
        try await journal.beginSession(id: "S3")
        try await journal.record(.source(fragment(0, "hello"), sessionId: "S3", epochMs: 1))
        let entry = try XCTUnwrap(TranscriptJournalEntry.translation(
            fragmentId: 0, outcome: .unavailable(.failed), sessionId: "S3", epochMs: 2))
        try await journal.record(entry)

        let recovered = await FileTranscriptJournal().pendingSession()
        XCTAssertEqual(recovered?.fragments.first?.translation, .unavailable(.failed))
    }

    /// A phrase whose translation never arrived recovers as unavailable, never as pending —
    /// pending would render as the English source in the Spanish pane.
    func testPhraseWithNoTranslationRecoversAsUnavailable() async throws {
        try await journal.beginSession(id: "S4")
        try await journal.record(.source(fragment(0, "hello"), sessionId: "S4", epochMs: 1))

        let recovered = await FileTranscriptJournal().pendingSession()
        XCTAssertEqual(recovered?.fragments.first?.translation, .unavailable(.timedOut))
        XCTAssertNotEqual(recovered?.fragments.first?.translation, .pending)
    }

    // MARK: - Crash safety

    /// THE CRASH TEST. A process killed mid-write leaves a torn last line. Everything before it
    /// must survive — that is the property the whole append-only design exists to provide.
    func testTruncatedJournalKeepsEveryWholeEntry() async throws {
        try await journal.beginSession(id: "S5")
        for index in 0..<20 {
            try await journal.record(.source(fragment(index, "phrase \(index)"),
                                             sessionId: "S5", epochMs: index))
        }

        // Simulate a kill halfway through writing entry 21.
        let url = try journalURL()
        var raw = try Data(contentsOf: url)
        raw.append(contentsOf: Array(#"{"kind":"source","fragmentId":20,"sess"#.utf8))
        try raw.write(to: url)

        let recovered = await FileTranscriptJournal().pendingSession()
        XCTAssertEqual(recovered?.fragments.count, 20,
                       "all 20 whole entries must survive; only the torn one is dropped")
        XCTAssertEqual(recovered?.fragments.last?.sourceText, "phrase 19")
    }

    /// Entries may reach disk out of order — recovery orders by phrase, not by file position.
    func testOutOfOrderEntriesRecoverInSpokenOrder() async throws {
        try await journal.beginSession(id: "S6")
        for index in [3, 0, 2, 1] {
            try await journal.record(.source(fragment(index, "phrase \(index)"),
                                             sessionId: "S6", epochMs: index))
        }

        let recovered = await FileTranscriptJournal().pendingSession()
        XCTAssertEqual(recovered?.fragments.map(\.id), [0, 1, 2, 3])
    }

    // MARK: - Lifecycle

    /// Discarding is the only thing that deletes the journal, and it is only ever reached
    /// through an explicit user action or a successful archive.
    func testDiscardRemovesTheJournal() async throws {
        try await journal.beginSession(id: "S7")
        try await journal.record(.source(fragment(0, "hello"), sessionId: "S7", epochMs: 1))
        var hasPending = await journal.hasPendingSession()
        XCTAssertTrue(hasPending)

        await journal.discard()
        hasPending = await journal.hasPendingSession()
        XCTAssertFalse(hasPending)
    }

    /// A journal left behind by a previous run is never silently overwritten: that would destroy
    /// the very meeting the recovery flow exists to protect.
    func testBeginSessionRefusesToOverwriteAPendingJournal() async throws {
        try await journal.beginSession(id: "S8")
        try await journal.record(.source(fragment(0, "hello"), sessionId: "S8", epochMs: 1))

        let second = FileTranscriptJournal()
        do {
            try await second.beginSession(id: "S9")
            XCTFail("opening over a pending journal must fail rather than destroy it")
        } catch {
            let recovered = await FileTranscriptJournal().pendingSession()
            XCTAssertEqual(recovered?.fragments.first?.sourceText, "hello",
                           "the original meeting must still be intact")
        }
    }

    // MARK: - Cost

    /// Writing phrase 500 must cost the same as writing phrase 1: the journal appends, it never
    /// rewrites. A cost proportional to meeting length is exactly the defect to avoid.
    func testWriteCostDoesNotGrowWithMeetingLength() async throws {
        try await journal.beginSession(id: "S10")

        let firstBatchStart = Date()
        for index in 0..<50 {
            try await journal.record(.source(fragment(index, "phrase \(index)"),
                                             sessionId: "S10", epochMs: index))
        }
        let firstBatch = Date().timeIntervalSince(firstBatchStart)

        for index in 50..<450 {
            try await journal.record(.source(fragment(index, "phrase \(index)"),
                                             sessionId: "S10", epochMs: index))
        }

        let lastBatchStart = Date()
        for index in 450..<500 {
            try await journal.record(.source(fragment(index, "phrase \(index)"),
                                             sessionId: "S10", epochMs: index))
        }
        let lastBatch = Date().timeIntervalSince(lastBatchStart)

        // Generous factor: this catches "the cost is proportional to the file", not jitter.
        XCTAssertLessThan(lastBatch, firstBatch * 5 + 0.5,
                          "writing late phrases must not cost dramatically more than early ones")
    }
}
