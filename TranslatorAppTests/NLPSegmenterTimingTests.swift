//
//  NLPSegmenterTimingTests.swift
//  TranslatorAppTests
//
//  Endpointing behaviour (008-fix-audio-pipeline-resilience, US3).
//
//  `testRepeatedIdenticalPartialsStillEmit` is the regression for symptom S2. Before the fix,
//  every repeat of the same partial cancelled the pending emission without re-arming it, so a
//  phrase spoken before a pause was withheld forever and never reached translation. That test
//  hangs until its timeout on the old code.
//

import XCTest
@testable import TranslatorApp

final class NLPSegmenterTimingTests: XCTestCase {

    private func makeSegmenter() -> NLPSegmenterService {
        NLPSegmenterService(qualityMetrics: QualityMetricsService(),
                            telemetry: NoopPipelineTelemetry())
    }

    private func segment(_ text: String, isFinal: Bool = false) -> SpeechSegment {
        SpeechSegment(text: text, isFinal: isFinal, confidence: 0.9)
    }

    /// Collects emitted phrases until `count` arrive or the deadline passes.
    private func collect(_ output: AsyncStream<SegmentedPhrase>,
                         count: Int,
                         timeout: TimeInterval) async -> [SegmentedPhrase] {
        await withTaskGroup(of: [SegmentedPhrase].self) { group in
            group.addTask {
                var collected: [SegmentedPhrase] = []
                for await phrase in output {
                    collected.append(phrase)
                    if collected.count >= count { break }
                }
                return collected
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return []
            }
            let first = await group.next() ?? []
            group.cancelAll()
            return first
        }
    }

    // MARK: - S2 regression

    /// THE S2 REGRESSION. The recogniser re-emits the same partial while the speaker pauses.
    /// Each repeat must re-arm the stability timer, not silently kill it.
    func testRepeatedIdenticalPartialsStillEmit() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        let phrase = "the meeting starts now"
        Task {
            // One genuine partial, then four identical repeats — normal pause behaviour.
            for _ in 0..<5 {
                continuation.yield(self.segment(phrase))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
        }

        let collected = await collect(output, count: 1, timeout: 4.0)
        continuation.finish()

        XCTAssertEqual(collected.count, 1,
                       "a phrase followed by identical repeats must still be emitted — this is S2")
        XCTAssertEqual(collected.first?.text, phrase)
    }

    // MARK: - Pending ceiling

    /// A tail that keeps changing re-arms the stability timer indefinitely. The independent
    /// ceiling must force it out anyway. The old ceiling was only evaluated when a new segment
    /// arrived with a non-empty pending suffix, so it could never rescue this case.
    func testCeilingForcesEmissionWhenTailKeepsChanging() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        Task {
            var words: [String] = []
            for index in 0..<14 {
                words.append("word\(index)")
                continuation.yield(self.segment(words.joined(separator: " ")))
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }

        let collected = await collect(output, count: 1, timeout: 5.0)
        continuation.finish()

        XCTAssertEqual(collected.count, 1,
                       "the 3 s ceiling must emit even while the tail keeps changing")
    }

    // MARK: - Terminators and short utterances

    func testTerminatorEmitsImmediately() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        continuation.yield(segment("this is a complete sentence."))
        let collected = await collect(output, count: 1, timeout: 2.0)
        continuation.finish()

        XCTAssertEqual(collected.first?.text, "this is a complete sentence.")
    }

    /// A complete one-word utterance must survive the short-utterance guard.
    func testCompleteShortUtteranceIsEmitted() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        continuation.yield(segment("Yes.", isFinal: true))
        let collected = await collect(output, count: 1, timeout: 2.0)
        continuation.finish()

        XCTAssertEqual(collected.first?.text, "Yes.")
    }

    /// A rotation resets the committed baseline, so text from the new recognition session is
    /// not mistaken for a continuation of the old one.
    func testGenerationChangeResetsCommittedBaseline() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        continuation.yield(segment("first committed sentence.", isFinal: false))
        try? await Task.sleep(nanoseconds: 400_000_000)
        continuation.yield(SpeechSegment(text: "brand new session text.",
                                         isFinal: false, confidence: 0.9,
                                         sessionGeneration: 1))

        let collected = await collect(output, count: 2, timeout: 4.0)
        continuation.finish()

        XCTAssertEqual(collected.count, 2)
        XCTAssertEqual(collected.last?.text, "brand new session text.",
                       "post-rotation text must not be diffed against the old session's commit")
    }
}
