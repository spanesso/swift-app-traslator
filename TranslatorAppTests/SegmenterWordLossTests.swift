//
//  SegmenterWordLossTests.swift
//  TranslatorAppTests
//
//  Words the segmenter lost or showed twice on its own, independently of the recogniser
//  (research 2026-09-15, findings P4, P5, P6, D1, D3). Every test here fails on the code as it
//  was when the diagnosis was written.
//

import XCTest
@testable import TranslatorApp

final class SegmenterWordLossTests: XCTestCase {

    private func makeSegmenter() -> NLPSegmenterService {
        NLPSegmenterService(qualityMetrics: QualityMetricsService(),
                            telemetry: NoopPipelineTelemetry())
    }

    /// Collects everything the segmenter emits while the input stays OPEN. Finishing the input
    /// triggers the trailing flush, which would hide exactly the strandings these tests look for.
    private actor PhraseSink {
        private(set) var phrases: [String] = []
        func append(_ text: String) { phrases.append(text) }
    }

    private func drain(_ output: AsyncStream<SegmentedPhrase>, into sink: PhraseSink) -> Task<Void, Never> {
        Task {
            for await phrase in output { await sink.append(phrase.text) }
        }
    }

    private func sleep(ms: Int) async {
        try? await Task.sleep(nanoseconds: UInt64(ms) * 1_000_000)
    }

    // MARK: - P4: a rotation must not strand the pending tail

    /// The recogniser rotated (new `sessionGeneration`) while the speaker was mid-phrase. The
    /// baseline was reset without emitting what was pending, and the armed timer then compared
    /// against the NEW transcript, so the phrase never left at all.
    func testPendingPhraseSurvivesARecogniserRotation() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let sink = PhraseSink()
        let reader = drain(await segmenter.processStream(input), into: sink)

        continuation.yield(SpeechSegment(text: "we need to migrate the courses to the new packet",
                                         isFinal: false, confidence: 0.9, sessionGeneration: 0))
        await sleep(ms: 200)
        continuation.yield(SpeechSegment(text: "okay and", isFinal: false, confidence: 0.9,
                                         sessionGeneration: 1))
        await sleep(ms: 1_500)

        let phrases = await sink.phrases
        reader.cancel()
        continuation.finish()
        XCTAssertTrue(phrases.contains { $0.contains("migrate the courses") },
                      "the phrase pending at the rotation was lost: \(phrases)")
    }

    // MARK: - P5: a short sentence before a longer one must not be skipped

    /// "Yes." is one word, so it did not qualify on the sentence path and was left behind; the
    /// sentence after it was committed and the anchor moved past it for good.
    func testOneWordReplyBeforeASentenceIsKept() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let sink = PhraseSink()
        let reader = drain(await segmenter.processStream(input), into: sink)

        continuation.yield(SpeechSegment(text: "Yes. I agree with that. And then",
                                         isFinal: false, confidence: 0.9))
        await sleep(ms: 1_500)

        let phrases = await sink.phrases
        reader.cancel()
        continuation.finish()
        XCTAssertTrue(phrases.contains { $0.contains("Yes") },
                      "the one-word reply was skipped: \(phrases)")
    }

    /// Same shape with a word that is NOT a standalone reply. It must not be emitted on its own
    /// (that is the shredding guard), but it must not disappear either.
    func testShortNonReplySentenceIsKeptWithWhatFollows() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let sink = PhraseSink()
        let reader = drain(await segmenter.processStream(input), into: sink)

        continuation.yield(SpeechSegment(text: "Hmm. I agree with that. And then we go",
                                         isFinal: false, confidence: 0.9))
        await sleep(ms: 2_000)

        let phrases = await sink.phrases
        reader.cancel()
        continuation.finish()
        XCTAssertTrue(phrases.joined(separator: " ").contains("Hmm"),
                      "the short sentence vanished: \(phrases)")
        XCTAssertFalse(phrases.contains { $0.trimmingCharacters(in: .punctuationCharacters) == "Hmm" },
                       "a non-reply word must not be emitted on its own: \(phrases)")
    }

    // MARK: - P6: a one-word leftover after a clause cut must eventually leave

    /// A clause cut committed the head and cancelled BOTH timers. Only the stability timer was
    /// re-armed, and it refuses a single word, so the leftover waited for speech that might never
    /// come — and was lost at the next stop or rotation.
    func testOneWordLeftoverAfterAClauseCutIsEventuallyEmitted() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let sink = PhraseSink()
        let reader = drain(await segmenter.processStream(input), into: sink)

        continuation.yield(SpeechSegment(
            text: "we reviewed the budget with the finance team yesterday and they approved most of it, so",
            isFinal: false, confidence: 0.9))
        await sleep(ms: 4_500)

        let phrases = await sink.phrases
        reader.cancel()
        continuation.finish()
        XCTAssertTrue(phrases.contains { $0.contains("approved most of it") },
                      "fixture: the clause cut must have happened: \(phrases)")
        XCTAssertTrue(phrases.contains { $0.trimmingCharacters(in: .punctuationCharacters) == "so" },
                      "the one-word leftover was stranded: \(phrases)")
    }

    // MARK: - D1: revising the last committed word must not re-emit the utterance

    /// Every anchor is a suffix of the committed text, so rewriting its LAST word defeats all of
    /// them. After three misses the segmenter reset and emitted the whole utterance again.
    func testRevisedLastWordDoesNotReemitTheUtterance() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let sink = PhraseSink()
        let reader = drain(await segmenter.processStream(input), into: sink)

        continuation.yield(SpeechSegment(text: "we will meet on tuesday.", isFinal: false, confidence: 0.9))
        await sleep(ms: 200)
        for text in ["we will meet on thursday. and then",
                     "we will meet on thursday. and then we review",
                     "we will meet on thursday. and then we review the plan"] {
            continuation.yield(SpeechSegment(text: text, isFinal: false, confidence: 0.9))
            await sleep(ms: 200)
        }
        await sleep(ms: 1_500)

        let phrases = await sink.phrases
        reader.cancel()
        continuation.finish()
        XCTAssertEqual(phrases.filter { $0.lowercased().contains("we will meet") }.count, 1,
                       "the utterance was shown twice: \(phrases)")
        XCTAssertTrue(phrases.contains { $0.contains("review the plan") },
                      "the new words must still arrive: \(phrases)")
    }

    // MARK: - D3: audio replayed into a new request must not be shown twice

    /// A rotation replays recent audio into the new request, so its first words repeat the end
    /// of what was already committed. The rotation path cleared the committed tail — the one
    /// thing that lets overlap trimming recognise the repeat.
    func testReplayedWordsAfterARotationAreNotShownTwice() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let sink = PhraseSink()
        let reader = drain(await segmenter.processStream(input), into: sink)

        continuation.yield(SpeechSegment(text: "let us review the budget now.",
                                         isFinal: false, confidence: 0.9, sessionGeneration: 0))
        await sleep(ms: 200)
        continuation.yield(SpeechSegment(text: "the budget now. next item is hiring",
                                         isFinal: false, confidence: 0.9, sessionGeneration: 1))
        await sleep(ms: 1_500)

        let phrases = await sink.phrases
        reader.cancel()
        continuation.finish()
        XCTAssertFalse(phrases.contains { $0.lowercased().hasPrefix("the budget now") },
                       "the replayed words were shown twice: \(phrases)")
        XCTAssertTrue(phrases.contains { $0.contains("next item is hiring") },
                      "the new words must still arrive: \(phrases)")
    }
}
