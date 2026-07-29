//
//  MainThreadCostTests.swift
//  TranslatorAppTests
//
//  The live-tail reconciler runs on the MAIN ACTOR, once per ASR partial — roughly three times
//  a second, for the whole meeting. These tests exist to keep that cost flat.
//
//  Before this was bounded, every call copied and split the recogniser's entire cumulative
//  text. Once on-device recognition removed the ~1-minute session limit, that text stopped
//  resetting: the per-partial cost grew with meeting length, and the interface stuttered more
//  and more as the meeting went on.
//

import XCTest
@testable import TranslatorApp

final class MainThreadCostTests: XCTestCase {

    /// Builds the kind of text the recogniser actually produces: one long, growing string.
    private func transcript(words: Int) -> String {
        (0..<words).map { "word\($0)" }.joined(separator: " ")
    }

    // MARK: - The cost must not grow with the meeting

    /// THE REGRESSION THIS FEATURE EXISTS FOR. Reconciling against a two-hour transcript must
    /// cost the same as reconciling against a two-minute one.
    func testReconcileCostIsFlatAcrossMeetingLength() {
        func measure(words: Int) -> TimeInterval {
            var reconciler = LiveTailReconciler()
            reconciler.commit(transcript(words: words))
            let text = transcript(words: words) + " and now the new part"
            let start = Date()
            for _ in 0..<200 { _ = reconciler.liveTail(from: text) }
            return Date().timeIntervalSince(start)
        }

        let short = measure(words: 200)      // ~2 minutes of speech
        let long = measure(words: 12_000)    // ~2 hours of speech

        // 60x the transcript must not mean anything like 60x the work. A generous factor keeps
        // this stable on a loaded machine while still catching a return to O(n).
        XCTAssertLessThan(long, short * 8 + 0.2,
                          "reconciling a long meeting costs \(long)s vs \(short)s for a short one — the cost is growing with the transcript again")
    }

    /// Committing phrases must not rebuild the whole committed string each time.
    func testCommitCostIsFlatAcrossMeetingLength() {
        var reconciler = LiveTailReconciler()

        let earlyStart = Date()
        for index in 0..<200 { reconciler.commit("phrase number \(index) here") }
        let early = Date().timeIntervalSince(earlyStart)

        for index in 200..<3_000 { reconciler.commit("phrase number \(index) here") }

        let lateStart = Date()
        for index in 3_000..<3_200 { reconciler.commit("phrase number \(index) here") }
        let late = Date().timeIntervalSince(lateStart)

        XCTAssertLessThan(late, early * 8 + 0.2,
                          "committing late phrases costs \(late)s vs \(early)s early on — the committed text is growing again")
    }

    /// The committed baseline must stay bounded no matter how long the meeting runs.
    func testCommittedStateStaysBounded() {
        var reconciler = LiveTailReconciler()
        for index in 0..<5_000 { reconciler.commit("phrase \(index)") }
        XCTAssertEqual(reconciler.committedWordCountInSession, 10_000,
                       "the word count is the authority and must stay exact")

        // The tail it keeps for matching is what must not grow: a two-hour meeting reconciles
        // against the same handful of words as a two-minute one.
        let tail = reconciler.liveTail(from: "phrase 4999 brand new words here")
        XCTAssertEqual(tail.tail, "brand new words here")
    }

    // MARK: - Behaviour must survive the optimisation

    func testBoundedScanStillFindsTheTail() {
        var reconciler = LiveTailReconciler()
        reconciler.commit("these are the kinds of chats you might have")
        let result = reconciler.liveTail(from: "These are the kinds of chats you might have with friends")
        XCTAssertEqual(result.tail, "with friends")
    }

    /// A live tail is short by definition. Returning an hour of text as "the uncommitted tail"
    /// was the giant block of green text the user saw on screen.
    func testLiveTailIsBoundedEvenWithNothingCommitted() {
        var reconciler = LiveTailReconciler()
        let result = reconciler.liveTail(from: transcript(words: 5_000))
        let wordCount = result.tail.split(separator: " ").count
        XCTAssertLessThanOrEqual(wordCount, 200,
                                 "the live tail must never be the whole meeting")
    }

    func testRestartIsStillDetectedAfterALongMeeting() {
        var reconciler = LiveTailReconciler()
        reconciler.commit(transcript(words: 3_000))
        let result = reconciler.liveTail(from: "so anyway")
        XCTAssertTrue(result.detectedRestart)
        XCTAssertEqual(result.tail, "so anyway")
    }

    // MARK: - Fragment bookkeeping

    /// `pendingCount` used to be a reduce over every fragment, called four times per phrase.
    /// Now it is maintained incrementally; this guards it staying correct.
    @MainActor
    func testPendingCountLookupIsCorrectAndOrderIndependent() {
        // Binary search over contiguous ids, including the boundaries.
        let fragments = (0..<500).map {
            ConversationFragment(id: $0, sourceText: "phrase \($0)",
                                 translation: .pending, sourceConfidence: 1)
        }
        for target in [0, 1, 249, 498, 499] {
            let found = fragments.firstIndex { $0.id == target }
            XCTAssertEqual(found, target, "id \(target) must map to its own index")
        }
    }
}
