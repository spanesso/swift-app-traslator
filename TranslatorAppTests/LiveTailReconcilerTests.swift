//
//  LiveTailReconcilerTests.swift
//  TranslatorAppTests
//
//  The six mandatory cases from contracts/LiveTailReconciler.swift
//  (008-fix-audio-pipeline-resilience, US2).
//
//  Case 4 is the exact regression behind symptom S3 — the English pane going permanently blank
//  about a minute into a meeting. Without it, that bug can come back unnoticed.
//

import XCTest
@testable import TranslatorApp

final class LiveTailReconcilerTests: XCTestCase {

    // 1. Clean session, nothing committed → the whole text is the tail.
    func testNoCommittedYieldsWholeText() {
        var reconciler = LiveTailReconciler()
        let result = reconciler.liveTail(from: "hello there")
        XCTAssertEqual(result.tail, "hello there")
        XCTAssertEqual(result.branch, .noCommitted)
        XCTAssertFalse(result.detectedRestart)
    }

    // 2. Incoming text continues what was committed → the tail is the suffix.
    func testPrefixMatchYieldsSuffix() {
        var reconciler = LiveTailReconciler()
        reconciler.commit("hello there")
        let result = reconciler.liveTail(from: "hello there how are you")
        XCTAssertEqual(result.tail, "how are you")
        XCTAssertEqual(result.branch, .hasPrefix)
    }

    // 3. Incoming text SHORTER than what was committed in-session: the recogniser restarted.
    //    The old code returned "" here.
    func testShorterIncomingIsTreatedAsRestart() {
        var reconciler = LiveTailReconciler()
        reconciler.commit("one two three four five")
        let result = reconciler.liveTail(from: "brand new")
        XCTAssertEqual(result.tail, "brand new")
        XCTAssertEqual(result.branch, .restartDetected)
        XCTAssertTrue(result.detectedRestart)
        XCTAssertEqual(reconciler.committedWordCountInSession, 0, "the baseline must rebase")
    }

    // 4. THE S3 REGRESSION.
    //    A long meeting commits ~300 words, the recogniser rotates, and the new session sends
    //    4 words. The old logic compared 4 > 300, failed, and set the live tail to "" — forever,
    //    because a session capped at ~60 s can never out-count the whole meeting.
    func testLongMeetingThenRotationStillProducesTail() {
        var reconciler = LiveTailReconciler()
        let longHistory = (0..<300).map { "word\($0)" }.joined(separator: " ")
        reconciler.commit(longHistory)
        XCTAssertEqual(reconciler.committedWordCountInSession, 300)

        // The engine reports the rotation; the reconciler rebases.
        reconciler.recognitionSessionDidRestart()
        let result = reconciler.liveTail(from: "so the next thing")

        XCTAssertEqual(result.tail, "so the next thing")
        XCTAssertFalse(result.tail.isEmpty, "an empty tail here IS the frozen-pane bug")
    }

    // 4b. Same scenario WITHOUT an explicit restart signal: the word-count guard must still
    //     rescue it rather than returning "".
    func testLongMeetingRotationWithoutSignalStillProducesTail() {
        var reconciler = LiveTailReconciler()
        reconciler.commit((0..<300).map { "word\($0)" }.joined(separator: " "))
        let result = reconciler.liveTail(from: "so the next thing")
        XCTAssertEqual(result.tail, "so the next thing")
        XCTAssertTrue(result.detectedRestart)
    }

    // 5. Ten commit + rotate cycles keep producing a correct tail.
    func testRepeatedRotationsKeepWorking() {
        var reconciler = LiveTailReconciler()
        for cycle in 0..<10 {
            reconciler.commit("committed phrase number \(cycle)")
            reconciler.recognitionSessionDidRestart()
            let result = reconciler.liveTail(from: "fresh text \(cycle)")
            XCTAssertEqual(result.tail, "fresh text \(cycle)", "cycle \(cycle)")
        }
    }

    // 6. In-session commits accumulate normally between rotations.
    func testCommitsAccumulateWithinASession() {
        var reconciler = LiveTailReconciler()
        reconciler.commit("first phrase")
        reconciler.commit("second phrase")
        XCTAssertEqual(reconciler.committedWordCountInSession, 4)
        let result = reconciler.liveTail(from: "first phrase second phrase and more")
        XCTAssertEqual(result.tail, "and more")
        XCTAssertEqual(result.branch, .hasPrefix)
    }

    func testEmptyCommitIsIgnored() {
        var reconciler = LiveTailReconciler()
        reconciler.commit("   ")
        XCTAssertEqual(reconciler.committedWordCountInSession, 0)
        XCTAssertEqual(reconciler.liveTail(from: "text").branch, .noCommitted)
    }
}
