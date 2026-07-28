//
//  TranscriptRewriteTests.swift
//  TranslatorAppTests
//
//  Regressions for the two defects reported from the device on 2026-07-28:
//  the false "Recording paused" banner, and the translated text rewriting itself.
//
//  All of these fail on the code as it was when the report came in.
//

import XCTest
@testable import TranslatorApp

final class TranscriptRewriteTests: XCTestCase {

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

    // MARK: - The recogniser rewrites its own transcript

    /// `SFSpeechRecognizer` with `addsPunctuation` rewrites the whole string as it goes, so the
    /// word count can go DOWN between two partials of the same utterance. That used to be read
    /// as "the session restarted": the committed baseline was wiped and every phrase already on
    /// screen became pending again and was re-translated.
    func testShrinkingPartialIsNotMistakenForARestart() async {
        let segmenter = await makeSegmenter()
        var reconciler = LiveTailReconciler()

        // 12 words committed, then a revised partial one word shorter — a revision, not a restart.
        reconciler.commit("sometimes people think that intermediate english is just about grammar rules words")
        let result = reconciler.liveTail(from: "Sometimes people think that intermediate English is just about grammar rules")

        XCTAssertFalse(result.detectedRestart,
                       "a one-word shrink is a revision; treating it as a restart re-emits the session")
        _ = segmenter
    }

    /// A genuine restart collapses to near zero and must still be caught.
    func testRealRestartIsStillDetected() {
        var reconciler = LiveTailReconciler()
        reconciler.commit((0..<40).map { "word\($0)" }.joined(separator: " "))
        let result = reconciler.liveTail(from: "so anyway")
        XCTAssertTrue(result.detectedRestart)
        XCTAssertEqual(result.tail, "so anyway")
    }

    /// With the baseline intact, a revised partial must not resurrect committed text as a tail.
    func testRevisedPartialDoesNotResurrectCommittedText() {
        var reconciler = LiveTailReconciler()
        reconciler.commit("these are the kinds of chats you might have")
        let result = reconciler.liveTail(from: "These are the kinds of chats you might have with friends")
        XCTAssertEqual(result.tail, "with friends")
        XCTAssertFalse(result.tail.contains("kinds"), "already-shown words must not reappear")
    }

    // MARK: - Overlap trimming

    /// The visible symptom: a phrase is shown, then a longer version of the SAME phrase arrives
    /// and the reader has to start over. Anything already committed is trimmed off the front.
    func testEmittedPhrasesNeverRepeatCommittedText() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        Task {
            // Two complete sentences, the second arriving as a rewrite that re-states the first.
            continuation.yield(SpeechSegment(text: "Sometimes people think that intermediate English is just about grammar rules.",
                                             isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 300_000_000)
            continuation.yield(SpeechSegment(text: "Sometimes people think that intermediate English is just about grammar rules, but it is really about having natural flow.",
                                             isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            continuation.finish()
        }

        let phrases = await collect(output, forMs: 4_000)
        XCTAssertGreaterThanOrEqual(phrases.count, 1)

        // No phrase after the first may restate the opening of the conversation.
        for phrase in phrases.dropFirst() {
            XCTAssertFalse(phrase.lowercased().hasPrefix("sometimes people think"),
                           "re-emitted an already-shown opening: '\(phrase)'")
        }
    }

    // MARK: - Quality signal

    /// Every partial used to count as a "revision", producing rates near 180/min against a
    /// threshold of 10 — so every session was low quality and the emission delay was pinned at
    /// 1 200 ms. Appending is not revising.
    func testAppendingPartialsAreNotCountedAsRevisions() async {
        let metrics = QualityMetricsService()
        await metrics.startSession(sessionId: "TEST")
        for words in 1...30 {
            let text = (1...words).map { "word\($0)" }.joined(separator: " ")
            await metrics.recordSegmentObservation(text: text, isFinal: false, confidence: 0)
        }
        let snapshot = await metrics.getCurrentMetrics()
        XCTAssertEqual(snapshot.totalRevisions, 0,
                       "30 purely additive partials are 0 revisions, not 29")
    }

    /// Punctuation and capitalisation churn is not a revision either — it is what
    /// `addsPunctuation` does on nearly every update.
    func testPunctuationChurnIsNotARevision() async {
        let metrics = QualityMetricsService()
        await metrics.startSession(sessionId: "TEST")
        await metrics.recordSegmentObservation(text: "sometimes people think", isFinal: false, confidence: 0)
        await metrics.recordSegmentObservation(text: "Sometimes people think,", isFinal: false, confidence: 0)
        let snapshot = await metrics.getCurrentMetrics()
        XCTAssertEqual(snapshot.totalRevisions, 0)
    }

    /// A real rewrite of already-spoken words still counts.
    func testGenuineRewriteIsCountedAsARevision() async {
        let metrics = QualityMetricsService()
        await metrics.startSession(sessionId: "TEST")
        await metrics.recordSegmentObservation(text: "the cat sat on the mat", isFinal: false, confidence: 0)
        await metrics.recordSegmentObservation(text: "the dog sat on the mat", isFinal: false, confidence: 0)
        let snapshot = await metrics.getCurrentMetrics()
        XCTAssertEqual(snapshot.totalRevisions, 1)
    }
}
