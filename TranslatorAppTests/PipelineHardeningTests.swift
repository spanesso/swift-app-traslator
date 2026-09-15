//
//  PipelineHardeningTests.swift
//  TranslatorAppTests
//
//  Privacy and observability guarantees added after the 2026-09-15 research: recognition never
//  leaves the device, the meeting never rides along in a backup, a dead capture path is reported,
//  and replay windows follow the rotation that asked for them.
//

import Speech
import XCTest
@testable import TranslatorApp

final class PipelineHardeningTests: XCTestCase {

    // MARK: - Nothing leaves the device

    func testRecognitionRequestNeverAllowsServerRecognition() {
        let request = AppleSFSpeechEngine.makeRequest(vocabulary: [])
        XCTAssertTrue(request.requiresOnDeviceRecognition)
        XCTAssertTrue(AppleSFSpeechEngine.makeRequest(vocabulary: ["Kubernetes"]).requiresOnDeviceRecognition)
    }

    /// Without local support the answer is "do not record", never "use the server".
    func testNoOnDeviceSupportRefusesToRecord() {
        XCTAssertThrowsError(try AppleSFSpeechEngine.verifyOnDeviceRecognition(supported: false)) { error in
            XCTAssertEqual(error as? SpeechEngineError, .onDeviceRecognitionUnavailable)
        }
        XCTAssertNoThrow(try AppleSFSpeechEngine.verifyOnDeviceRecognition(supported: true))
    }

    func testBackupExclusionMarksADirectoryAndItsFutureContents() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        XCTAssertFalse(BackupExclusion.isExcluded(directory), "fixture: a new directory is backed up")
        XCTAssertTrue(BackupExclusion.exclude(directory))
        XCTAssertTrue(BackupExclusion.isExcluded(directory))
    }

    @MainActor
    func testLiveJournalIsExcludedFromBackups() async throws {
        let journal = FileTranscriptJournal()
        await journal.discard()
        try await journal.beginSession(id: "BACKUP")
        defer { Task { await journal.discard() } }

        let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask,
                                                    appropriateFor: nil, create: true)
            .appendingPathComponent("LiveTranscript", isDirectory: true)
        XCTAssertTrue(BackupExclusion.isExcluded(directory))
    }

    // MARK: - A dead capture path is visible

    func testStallIsReportedOnceAndItsEndIsReported() {
        var detector = TapStallDetector()
        XCTAssertNil(detector.observe(buffers: 47, intervalMs: 1_000))
        XCTAssertNil(detector.observe(buffers: 0, intervalMs: 1_000))
        XCTAssertEqual(detector.observe(buffers: 0, intervalMs: 1_000), .stalled(silentMs: 2_000))
        XCTAssertNil(detector.observe(buffers: 0, intervalMs: 1_000), "one report per stall, not one per second")
        XCTAssertEqual(detector.observe(buffers: 12, intervalMs: 1_000), .recovered(afterMs: 3_000))
        XCTAssertNil(detector.observe(buffers: 47, intervalMs: 1_000))
    }

    /// A quiet room still delivers buffers; only their absence is a stall.
    func testContinuousBuffersAreNeverAStall() {
        var detector = TapStallDetector()
        for _ in 0..<120 { XCTAssertNil(detector.observe(buffers: 47, intervalMs: 1_000)) }
    }

    func testOneMissedIntervalIsNotAStall() {
        var detector = TapStallDetector()
        XCTAssertNil(detector.observe(buffers: 0, intervalMs: 1_000))
        XCTAssertNil(detector.observe(buffers: 47, intervalMs: 1_000))
        XCTAssertNil(detector.observe(buffers: 0, intervalMs: 1_000))
    }

    // MARK: - Replay windows

    func testDeafRotationReplaysEverythingSinceTheLastTranscript() {
        XCTAssertEqual(AppleSFSpeechEngine.replayWindowMs(trigger: .deaf, msSinceLastTranscript: 4_000), 4_500)
    }

    /// Any other rotation only covers the swap: replaying more re-shows committed words.
    func testOtherRotationsReplayOnlyTheSwapWindow() {
        for trigger in [RestartTrigger.isFinal, .noSpeech, .watchdog, .routeChange, .manual] {
            XCTAssertEqual(AppleSFSpeechEngine.replayWindowMs(trigger: trigger, msSinceLastTranscript: 30_000),
                           1_500, "\(trigger)")
        }
    }

    // MARK: - Recent-phrase filter

    func testAnEchoOutsideTheWindowIsNotADuplicate() {
        var filter = RecentPhraseFilter()
        let start = MonotonicClock.now()
        XCTAssertFalse(filter.isDuplicate("we will ship on friday", at: start))
        XCTAssertTrue(filter.isDuplicate("we will ship on friday", at: start.advanced(by: .seconds(2))))
        XCTAssertFalse(filter.isDuplicate("we will ship on friday", at: start.advanced(by: .seconds(40))),
                       "said again much later, it is a new phrase")
    }
}
