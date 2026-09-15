//
//  AudioLevelMonitorTests.swift
//  TranslatorAppTests
//
//  The input meter exists so a speaker the recogniser cannot hear stops being invisible.
//  Nothing recovers audio that never reached the microphone; this makes the loss visible while
//  the meeting is still happening.
//

import XCTest
@testable import TranslatorApp

final class AudioLevelMonitorTests: XCTestCase {

    private func makeMonitor() -> AudioLevelMonitor { AudioLevelMonitor() }

    // MARK: - Reading the level

    func testSilenceReadsAsZero() {
        let monitor = makeMonitor()
        monitor.record(rms: 0)
        XCTAssertEqual(monitor.reading().level, 0)
        XCTAssertFalse(monitor.reading().hasSpeechEnergy)
    }

    func testFullScaleReadsAsOne() {
        let monitor = makeMonitor()
        monitor.record(rms: 1.0)
        XCTAssertEqual(monitor.reading().level, 1.0, accuracy: 0.01)
        XCTAssertTrue(monitor.reading().hasSpeechEnergy)
    }

    /// The whole point: a quiet distant speaker must read as present-but-low, not as silence.
    /// If this collapsed to zero the meter would be useless for exactly the case it exists for.
    func testQuietSpeechIsVisibleButLow() {
        let monitor = makeMonitor()
        monitor.record(rms: 0.01)   // ≈ -40 dBFS: someone talking across a table
        let reading = monitor.reading()
        XCTAssertGreaterThan(reading.level, 0.05, "quiet speech must still move the meter")
        XCTAssertLessThan(reading.level, 0.5, "and must be clearly distinguishable from close speech")
        XCTAssertTrue(reading.hasSpeechEnergy, "-40 dBFS is above the speech floor")
    }

    /// Room noise must NOT read as speech, or the indicator means nothing.
    func testRoomNoiseIsNotReportedAsSpeech() {
        let monitor = makeMonitor()
        monitor.record(rms: 0.001)  // ≈ -60 dBFS
        XCTAssertFalse(monitor.reading().hasSpeechEnergy)
    }

    /// The scale is in decibels on purpose: a linear-in-amplitude meter barely moves for normal
    /// speech, which is why it would fail to show the difference this feature is about.
    func testScaleIsPerceptuallyUsable() {
        let monitor = makeMonitor()
        monitor.record(rms: 0.01)
        let quiet = monitor.reading().level
        monitor.record(rms: 0.1)
        let normal = monitor.reading().level
        monitor.record(rms: 0.5)
        let loud = monitor.reading().level

        XCTAssertGreaterThan(normal, quiet + 0.15, "quiet and normal must be clearly different")
        XCTAssertGreaterThan(loud, normal + 0.1, "normal and loud must be clearly different")
    }

    // MARK: - Peak hold

    /// A short word must survive until the interface next polls, which it does ten times a
    /// second — otherwise a quick "yes" would never appear on the meter at all.
    func testPeakSurvivesASubsequentQuietBuffer() {
        let monitor = makeMonitor()
        monitor.record(rms: 0.8)
        monitor.record(rms: 0.0)
        let reading = monitor.reading()
        XCTAssertEqual(reading.level, 0, "the instantaneous level follows the signal down")
        XCTAssertGreaterThan(reading.recentPeak, 0.8, "but the recent peak is held")
    }

    // MARK: - Buffer path

    /// The version called from the audio tap must agree with the direct one. This is the path
    /// that actually runs, and it runs on the real-time thread.
    func testBufferPathMatchesDirectRms() {
        let monitor = makeMonitor()
        let samples = [Float](repeating: 0.5, count: 1024)
        samples.withUnsafeBufferPointer { pointer in
            monitor.record(samples: pointer.baseAddress!, count: pointer.count)
        }
        let fromBuffer = monitor.reading().level

        let direct = makeMonitor()
        direct.record(rms: 0.5)
        XCTAssertEqual(fromBuffer, direct.reading().level, accuracy: 0.01)
    }

    func testEmptyBufferIsIgnored() {
        let monitor = makeMonitor()
        monitor.record(rms: 0.5)
        let before = monitor.reading().level
        let empty = [Float]()
        empty.withUnsafeBufferPointer { pointer in
            monitor.record(samples: pointer.baseAddress ?? UnsafePointer(bitPattern: 1)!, count: 0)
        }
        XCTAssertEqual(monitor.reading().level, before, "a zero-length buffer must change nothing")
    }

    func testResetClearsEverything() {
        let monitor = makeMonitor()
        monitor.record(rms: 0.9)
        monitor.reset()
        let reading = monitor.reading()
        XCTAssertEqual(reading.level, 0)
        XCTAssertEqual(reading.recentPeak, 0)
        XCTAssertFalse(reading.hasSpeechEnergy)
    }
}
