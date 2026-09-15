//
//  TaskCompletionTests.swift
//  TranslatorAppTests
//
//  The bounded wait used by every stop (field log 2026-09-15: the log ended at
//  "[AudioCapture] stopped" and the stop never finished).
//

import XCTest
@testable import TranslatorApp

final class TaskCompletionTests: XCTestCase {

    /// A task that does not respond to cancellation — SpeechAnalyzer's finalisation, for one.
    /// The wait used to cancel it and then wait for it anyway, so a stop could hang forever.
    func testWaitReturnsOnTimeEvenIfTheTaskIgnoresCancellation() async {
        let stubborn = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { continuation.resume() }
            }
        }
        let startedAt = MonotonicClock.now()

        let finished = await TaskCompletion.wait(for: stubborn, upToMs: 200)

        XCTAssertFalse(finished)
        XCTAssertLessThan(MonotonicClock.msSince(startedAt), 1_000,
                          "the wait is bounded; it must not follow a task that ignores cancellation")
    }

    func testWaitReportsATaskThatFinishesInTime() async {
        let quick = Task { _ = try? await Task.sleep(nanoseconds: 50_000_000) }
        let finished = await TaskCompletion.wait(for: quick, upToMs: 1_000)
        XCTAssertTrue(finished)
    }
}
