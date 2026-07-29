//
//  TranscriptShreddingTests.swift
//  TranslatorAppTests
//
//  Regression for the conversation being shredded into one- and two-word phrases
//  (field report 2026-07-28).
//
//  With difficult audio the recogniser's `addsPunctuation` sprinkles full stops between words.
//  Honouring each one produced "It's." "kind." "of." "we need." — each sent off to be translated
//  on its own, and a translator handed "of." has nothing to work with, so it echoed the input
//  back. That is how English ended up filling the Spanish pane.
//

import XCTest
@testable import TranslatorApp

final class TranscriptShreddingTests: XCTestCase {

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

    // MARK: - The rule itself

    func testPeriodAfterOneWordIsNotAnUtterance() async {
        let segmenter = makeSegmenter()
        // The exact fragments seen in the field.
        for noise in ["of.", "kind.", "figure.", "do.", "idea.", "can.", "show.", "see."] {
            let completes = await segmenter.terminatorCompletesUtterance(noise)
            XCTAssertFalse(completes,
                           "'\(noise)' is the recogniser punctuating mid-sentence, not a sentence")
        }
    }

    func testPeriodAfterTwoWordsIsNotAnUtterance() async {
        let segmenter = makeSegmenter()
        for noise in ["we need.", "out how.", "but we.", "wants to."] {
            let completes = await segmenter.terminatorCompletesUtterance(noise)
            XCTAssertFalse(completes, "'\(noise)' is grammatically open; the period is noise")
        }
    }

    func testPeriodAfterThreeOrMoreWordsIsAnUtterance() async {
        let segmenter = makeSegmenter()
        let short = await segmenter.terminatorCompletesUtterance("in two minutes.")
        XCTAssertTrue(short)
        let long = await segmenter.terminatorCompletesUtterance(
            "these are the kinds of chats you might have.")
        XCTAssertTrue(long)
    }

    /// Feature 006 (SC-003) went out of its way to stop dropping genuine one-word replies.
    /// They must keep arriving instantly.
    func testGenuineStandaloneRepliesStillCountAsUtterances() async {
        let segmenter = makeSegmenter()
        for reply in ["Yes.", "Okay.", "No.", "Right.", "Sure.", "Exactly.", "yeah!"] {
            let completes = await segmenter.terminatorCompletesUtterance(reply)
            XCTAssertTrue(completes,
                          "'\(reply)' is a real standalone reply and must not be delayed")
        }
    }

    func testTextWithoutATerminatorIsNeverAnUtterance() async {
        let segmenter = makeSegmenter()
        let completes = await segmenter.terminatorCompletesUtterance("this has no full stop")
        XCTAssertFalse(completes)
    }

    // MARK: - End to end

    /// THE FIELD REGRESSION. A stream of one-word partials each ending in a period must not
    /// produce one phrase per word.
    func testPunctuationStormDoesNotShredTheConversation() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        // Exactly the shape seen in the field: the cumulative text grows one word at a time and
        // the recogniser puts a full stop after each.
        let words = ["It's.", "kind.", "of.", "we", "need.", "figure.", "out", "how.",
                     "do.", "but", "we.", "idea.", "can.", "show.", "somebody."]
        Task {
            var cumulative: [String] = []
            for word in words {
                cumulative.append(word)
                continuation.yield(SpeechSegment(text: cumulative.joined(separator: " "),
                                                 isFinal: false, confidence: 0.9))
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            continuation.finish()
        }

        let phrases = await collect(output, forMs: 6_000)

        XCTAssertFalse(phrases.isEmpty, "the words must still come out, just not one at a time")
        let oneWorders = phrases.filter { $0.split(separator: " ").count == 1 }
        XCTAssertTrue(oneWorders.isEmpty,
                      "emitted one-word fragments: \(oneWorders) — the conversation is being shredded again")
    }

    /// Deferring is not dropping. Everything spoken still reaches the output.
    func testDeferredWordsAreNotLost() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        Task {
            continuation.yield(SpeechSegment(text: "we.", isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 200_000_000)
            continuation.yield(SpeechSegment(text: "we need. to figure out how.",
                                             isFinal: false, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            continuation.finish()
        }

        let phrases = await collect(output, forMs: 5_000)
        let combined = phrases.joined(separator: " ").lowercased()
        XCTAssertTrue(combined.contains("we need"),
                      "the deferred words must reappear later, not vanish: got \(phrases)")
    }

    /// A real final result from the recogniser is still trusted unconditionally, however short.
    func testFinalResultIsAlwaysTrusted() async {
        let segmenter = makeSegmenter()
        let (input, continuation) = AsyncStream.makeStream(of: SpeechSegment.self)
        let output = await segmenter.processStream(input)

        Task {
            continuation.yield(SpeechSegment(text: "Sure.", isFinal: true, confidence: 0.9))
            try? await Task.sleep(nanoseconds: 300_000_000)
            continuation.finish()
        }

        let phrases = await collect(output, forMs: 3_000)
        XCTAssertEqual(phrases.first, "Sure.")
    }

    // MARK: - The Spanish pane must never show English

    /// The pending state carries no text of its own. Rendering the English source there is what
    /// made a failed translation indistinguishable from a real one.
    func testPendingFragmentExposesNoSourceText() {
        let fragment = ConversationFragment(id: 0,
                                            sourceText: "we are going to talk about this",
                                            translation: .pending,
                                            sourceConfidence: 0.9)
        XCTAssertEqual(fragment.displayTranslation, "",
                       "a pending fragment must not offer its English text as a translation")
        XCTAssertFalse(fragment.displayTranslation.contains("talk about"))
    }
}
