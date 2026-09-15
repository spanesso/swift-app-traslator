//
//  QualityCalibrationTests.swift
//  TranslatorAppTests
//
//  The verdict that sets the emission delay, pinned to the numbers observed in the field.
//
//  This classification is not a diagnostic: it chooses between a 700 ms and a 1 200 ms delay on
//  every phrase, so getting it wrong is felt directly as lag. Two traces drove these tests — one
//  where every session was low quality from the first second, and one where the verdict flipped
//  three times in a minute around a single threshold.
//

import XCTest
@testable import TranslatorApp

final class QualityCalibrationTests: XCTestCase {

    private typealias Quality = QualityMetricsService

    // MARK: - Where the bar sits

    /// The rate of a meeting that is working. Classifying this as low quality is what pinned the
    /// delay at 1 200 ms for entire sessions.
    func testAWorkingMeetingRateIsNotLowQuality() {
        XCTAssertFalse(Quality.classify(revisionRate: 34.4, fragmentation: 0.07,
                                        confidence: nil, wasLow: false))
        XCTAssertFalse(Quality.classify(revisionRate: 36.5, fragmentation: 0.07,
                                        confidence: nil, wasLow: false))
    }

    func testGenuinelyBadRecognitionIsStillCaught() {
        XCTAssertTrue(Quality.classify(revisionRate: 60, fragmentation: 0.07,
                                       confidence: nil, wasLow: false))
        XCTAssertTrue(Quality.classify(revisionRate: 10, fragmentation: 0.30,
                                       confidence: nil, wasLow: false))
    }

    // MARK: - Hysteresis

    /// Between the two thresholds the verdict must hold, whichever it was. A single threshold at
    /// the operating point produced 34.4 → 36.5 → 34.7 in one minute, each flip changing the
    /// emission delay by half a second.
    func testTheVerdictHoldsBetweenTheThresholds() {
        XCTAssertFalse(Quality.classify(revisionRate: 40, fragmentation: 0.07,
                                        confidence: nil, wasLow: false),
                       "40/min must not be enough to ENTER low quality")
        XCTAssertTrue(Quality.classify(revisionRate: 40, fragmentation: 0.07,
                                       confidence: nil, wasLow: true),
                      "40/min must not be enough to LEAVE it either")
    }

    func testItLeavesLowQualityOnceItReallyRecovers() {
        XCTAssertFalse(Quality.classify(revisionRate: 30, fragmentation: 0.07,
                                        confidence: nil, wasLow: true))
    }

    func testThresholdsLeaveARealGap() {
        XCTAssertGreaterThan(Quality.enterLowRevisionRate, Quality.leaveLowRevisionRate,
                             "without a gap this is a single threshold and it will flap")
    }

    // MARK: - The confidence term

    /// On-device recognition reports no confidence at all, so the term must stay inert rather
    /// than reading "no data" as "no confidence".
    func testAbsentConfidenceIsNotReadAsBadConfidence() {
        XCTAssertFalse(Quality.classify(revisionRate: 10, fragmentation: 0.07,
                                        confidence: nil, wasLow: false))
        XCTAssertTrue(Quality.classify(revisionRate: 10, fragmentation: 0.07,
                                       confidence: 0.2, wasLow: false),
                      "a real low confidence, when an engine reports one, still counts")
    }

    // MARK: - Warm-up

    /// `revisionRate` divides by elapsed session time, so seconds in, a single revision reads as
    /// tens per minute. Every meeting used to open with a LOW verdict built on that noise — and
    /// therefore with the slowest emission delay exactly where the first phrases arrive.
    func testTheOpeningOfAMeetingIsNotJudgedOnNoise() async {
        let metrics = QualityMetricsService()
        await metrics.startSession(sessionId: "TEST")

        // Two genuine rewrites, one second into the session: a rate of ~120/min on no evidence.
        await metrics.recordSegmentObservation(text: "the cat sat on the mat",
                                               isFinal: false, confidence: 0)
        await metrics.recordSegmentObservation(text: "the dog sat on the mat",
                                               isFinal: false, confidence: 0)
        await metrics.recordSegmentObservation(text: "the bird sat on the mat",
                                               isFinal: false, confidence: 0)

        let snapshot = await metrics.getCurrentMetrics()
        XCTAssertGreaterThan(snapshot.revisionRate, Quality.enterLowRevisionRate,
                             "the fixture must produce the inflated opening rate")

        let verdict = await metrics.isLowQualitySpeech()
        XCTAssertFalse(verdict, "judged the meeting on its first second and called it low quality")
    }

    /// The guard is warm-up, not a permanent exemption: it must be a real bound on evidence.
    func testWarmUpIsBounded() {
        XCTAssertGreaterThan(Quality.warmUpObservations, 0)
        XCTAssertGreaterThan(Quality.warmUpSeconds, 0)
        XCTAssertLessThanOrEqual(Quality.warmUpSeconds, 60,
                                 "a warm-up longer than a minute would cover most short meetings")
    }
}
