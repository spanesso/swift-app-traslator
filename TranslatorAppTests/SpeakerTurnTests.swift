//
//  SpeakerTurnTests.swift
//  TranslatorAppTests
//
//  Regressions for the field report of 2026-08-05: "one person speaks and it is fine, but when
//  someone else starts it takes far too long".
//
//  The trace behind it showed a recogniser that restarts its transcript at an utterance boundary
//  WITHOUT a final result and without ending the task — so `sessionGeneration` never changes and
//  nothing downstream is told. Every test here fails on the code as it was when the report came
//  in.
//

import XCTest
@testable import TranslatorApp

final class SpeakerTurnTests: XCTestCase {

    private func makeSegmenter() -> NLPSegmenterService {
        NLPSegmenterService(qualityMetrics: QualityMetricsService(),
                            telemetry: NoopPipelineTelemetry())
    }

    private func collect(_ output: AsyncStream<SegmentedPhrase>,
                         forMs milliseconds: Int) async -> [String] {
        await withTaskGroup(of: [String].self) { group in
            group.addTask {
                var collected: [String] = []
                for await phrase in output { collected.append(phrase.text) }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    // MARK: - Telling a restart from a revision

    func testTranscriptCollapseIsARestart() {
        XCTAssertTrue(NLPSegmenterService.didRestartTranscript(
            previous: "so we have to migrate this to the new SDK first and then rebuild",
            incoming: "okay so"))
    }

    /// The defect this must not reintroduce: `addsPunctuation` shortens the string routinely, and
    /// reading that as a restart wipes the baseline and re-emits the whole session.
    func testOneWordShrinkIsARevisionNotARestart() {
        XCTAssertFalse(NLPSegmenterService.didRestartTranscript(
            previous: "sometimes people think that intermediate english is just about grammar rules words",
            incoming: "Sometimes people think that intermediate English is just about grammar rules"))
    }

    /// Nothing to compare against yet — the opening words of a meeting are not a restart.
    func testShortOpeningIsNeverARestart() {
        XCTAssertFalse(NLPSegmenterService.didRestartTranscript(previous: "so we", incoming: "so"))
        XCTAssertFalse(NLPSegmenterService.didRestartTranscript(previous: "", incoming: "okay"))
    }

    // MARK: - The pending tail is not stranded by the turn

    /// The phrase the FIRST speaker was still finishing must leave immediately when the
    /// recogniser abandons its transcript. Held back, it was measured against a baseline that no
    /// longer existed and only escaped through the 3 s ceiling — which is the delay the user
    /// reported, paid at every change of speaker.
    func testPendingPhraseIsFlushedWhenTheRecogniserStartsANewUtterance() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        Task {
            // Speaker A, still mid-phrase: no terminator, so nothing forces an emission.
            continuation.yield(SpeechSegment(text: "we need to migrate the courses to the new packet",
                                             isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 200_000_000)
            // Speaker B: the recogniser threw the transcript away and started again. Same
            // generation — no rotation happened.
            continuation.yield(SpeechSegment(text: "okay and", isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            continuation.finish()
        }

        // Well inside the 3 s ceiling: if this only passes at 3 s, the bug is back.
        let phrases = await collect(output, forMs: 1_800)
        XCTAssertTrue(phrases.contains { $0.contains("migrate the courses") },
                      "speaker A's pending phrase was stranded by the turn: \(phrases)")
    }

    /// After the turn, the new speaker's words must flow. The baseline used to keep pointing into
    /// the discarded transcript, so `pendingSuffix` returned nothing on every update.
    func testNewSpeakerIsTranscribedAfterTheTurn() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        Task {
            continuation.yield(SpeechSegment(text: "we need to migrate the courses to the new packet.",
                                             isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 200_000_000)
            continuation.yield(SpeechSegment(text: "okay and", isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 200_000_000)
            // No terminator: this can only reach the output if the baseline followed the
            // recogniser across the turn. Left pointing at the discarded transcript, the tail
            // computes as empty and the second speaker never appears at all.
            continuation.yield(SpeechSegment(text: "okay and who is going to update that library",
                                             isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            continuation.finish()
        }

        // Tight on purpose: 2 s is inside the 3 s ceiling, so passing means the phrase left
        // through the normal path and not through the last-resort watchdog.
        let phrases = await collect(output, forMs: 2_000)
        XCTAssertTrue(phrases.contains { $0.lowercased().contains("update that library") },
                      "the second speaker never reached the output: \(phrases)")
    }

    /// The stall that had no way out. When the committed baseline can no longer be located in the
    /// recogniser's text, the old code returned "" — and because the test it used could only get
    /// FALSER as the window grew, it returned "" for the rest of the meeting. No phrase was ever
    /// emitted again and nothing reported a fault.
    func testSegmenterRecoversWhenTheBaselineCanNeverBeFoundAgain() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        Task {
            // Commit a short phrase so the baseline is small — the case the ratio test misses.
            continuation.yield(SpeechSegment(text: "yes exactly that is right.",
                                             isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 300_000_000)
            // Unrelated text, never shorter than half the baseline, sharing no anchor with it.
            for words in 3...9 {
                let text = (1...words).map { "alpha\($0)" }.joined(separator: " ")
                continuation.yield(SpeechSegment(text: text, isFinal: false, confidence: 0.9))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            continuation.finish()
        }

        let phrases = await collect(output, forMs: 4_000)
        XCTAssertTrue(phrases.contains { $0.contains("alpha") },
                      "the segmenter never recovered its baseline and went silent: \(phrases)")
    }

    // MARK: - Quality classification

    /// A working meeting sits at 15–30 revisions/min. Classifying that as low quality pinned the
    /// emission delay at 1 200 ms for the whole session, so the 700 ms path never ran and a short
    /// pause between speakers was never short enough to release the phrase.
    func testARealMeetingRevisionRateIsNotLowQuality() async {
        let metrics = QualityMetricsService()
        await metrics.startSession(sessionId: "TEST")

        // ~20 genuine rewrites, the rate observed in the field trace of a session that was working.
        for index in 0..<20 {
            await metrics.recordSegmentObservation(text: "the cat sat on mat \(index)",
                                                   isFinal: false, confidence: 0)
            await metrics.recordSegmentObservation(text: "the dog sat on mat \(index)",
                                                   isFinal: false, confidence: 0)
        }
        let snapshot = await metrics.getCurrentMetrics()
        XCTAssertGreaterThan(snapshot.totalRevisions, 10, "the fixture must produce real revisions")
        XCTAssertEqual(snapshot.avgConfidence, 0,
                       "on-device partials report no confidence — the term must stay inert")
    }
}
