//
//  RecordingSessionStateTests.swift
//  TranslatorAppTests
//
//  State transitions from data-model.md §2 (008-fix-audio-pipeline-resilience, US5).
//
//  The prohibition on `suspended → idle` is the whole point: allowing that edge is exactly what
//  let an unattended alarm end a recording session as if the user had pressed stop.
//

import XCTest
@testable import TranslatorApp

final class RecordingSessionStateTests: XCTestCase {

    // MARK: - Legal transitions

    func testIdleToActive() {
        XCTAssertTrue(RecordingSessionState.idle.canTransition(to: .active))
    }

    func testActiveToSuspended() {
        XCTAssertTrue(RecordingSessionState.active.canTransition(to: .suspended(.systemInterruption)))
    }

    func testSuspendedToActiveIsHowResumingWorks() {
        let suspended = RecordingSessionState.suspended(.systemInterruption)
        XCTAssertTrue(suspended.canTransition(to: .active))
    }

    func testSuspendedToStoppingIsTheOnlyGiveUpPath() {
        let suspended = RecordingSessionState.suspended(.systemInterruption)
        XCTAssertTrue(suspended.canTransition(to: .stopping))
    }

    func testActiveToStoppingAndStoppingToIdle() {
        XCTAssertTrue(RecordingSessionState.active.canTransition(to: .stopping))
        XCTAssertTrue(RecordingSessionState.stopping.canTransition(to: .idle))
    }

    // MARK: - The forbidden edge

    /// An interruption must never take the session straight to idle. Every route out of
    /// `suspended` goes through `active` (resumed) or `stopping` (explicit give-up).
    func testSuspendedCannotGoDirectlyToIdle() {
        for reason in AudioInterruptionReason.allCases {
            let suspended = RecordingSessionState.suspended(reason)
            XCTAssertFalse(suspended.canTransition(to: .idle),
                           "suspended(\(reason.rawValue)) → idle must be rejected")
        }
    }

    func testIdleCannotJumpToSuspended() {
        XCTAssertFalse(RecordingSessionState.idle.canTransition(to: .suspended(.routeChanged)))
    }

    func testStoppingCannotGoBackToActive() {
        XCTAssertFalse(RecordingSessionState.stopping.canTransition(to: .active))
    }

    // MARK: - Derived properties

    /// A suspended session is STILL a recording session. Reporting otherwise is what made the
    /// UI offer "start recording" mid-meeting and abandon the captured history.
    func testSuspendedCountsAsRecording() {
        XCTAssertTrue(RecordingSessionState.suspended(.systemInterruption).isRecording)
        XCTAssertTrue(RecordingSessionState.active.isRecording)
        XCTAssertFalse(RecordingSessionState.idle.isRecording)
        XCTAssertFalse(RecordingSessionState.stopping.isRecording)
    }

    func testSuspensionReasonIsCarried() {
        XCTAssertEqual(RecordingSessionState.suspended(.routeChanged).suspensionReason, .routeChanged)
        XCTAssertNil(RecordingSessionState.active.suspensionReason)
    }

    func testInterruptionReasonNeverClaimsAPermissionsProblem() {
        for reason in AudioInterruptionReason.allCases {
            let message = reason.userFacingMessage.lowercased()
            XCTAssertFalse(message.contains("permission"),
                           "\(reason.rawValue) must not be reported as a permissions problem")
            XCTAssertTrue(reason.recoversAutomatically)
        }
    }
}
