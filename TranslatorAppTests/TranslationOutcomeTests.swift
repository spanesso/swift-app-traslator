//
//  TranslationOutcomeTests.swift
//  TranslatorAppTests
//
//  Echo detection and recognition-error classification.
//

import XCTest
@testable import TranslatorApp

final class TranslationOutcomeTests: XCTestCase {

    // MARK: - Echo detection

    /// A service handed a fragment it cannot work with may return the input unchanged. Stored as
    /// a translation, that is English sitting in the Spanish pane looking exactly like a result.
    func testIdenticalResultIsNotATranslation() {
        let source = "we are going to talk about everyday conversations"
        let outcome = TranslationOutcome.forResult(source, source: source)
        XCTAssertEqual(outcome, .unavailable(.notTranslated))
    }

    /// Case and punctuation churn must not hide an echo.
    func testEchoIsDetectedThroughCaseAndPunctuation() {
        let outcome = TranslationOutcome.forResult("These are the kinds of chats.",
                                                   source: "these are the kinds of chats")
        XCTAssertEqual(outcome, .unavailable(.notTranslated))
    }

    func testRealTranslationIsKept() {
        let outcome = TranslationOutcome.forResult("estas son las conversaciones cotidianas",
                                                   source: "these are everyday conversations")
        XCTAssertEqual(outcome, .translated("estas son las conversaciones cotidianas"))
    }

    /// THE FALSE-POSITIVE GUARD. Plenty of one- and two-word phrases are genuinely identical in
    /// both languages. Flagging those would invent a failure that never happened.
    func testShortIdenticalPhrasesAreNotFlagged() {
        for phrase in ["No.", "OK.", "Hotel", "normal", "chocolate", "actor natural"] {
            let outcome = TranslationOutcome.forResult(phrase, source: phrase)
            XCTAssertEqual(outcome, .translated(phrase),
                           "'\(phrase)' can legitimately be identical in both languages")
        }
    }

    func testEmptyResultIsUnavailable() {
        XCTAssertEqual(TranslationOutcome.forResult("   ", source: "anything at all here"),
                       .unavailable(.emptyResult))
    }

    func testWhitespaceIsTrimmedFromARealTranslation() {
        XCTAssertEqual(TranslationOutcome.forResult("  hola mundo  ", source: "hello world now"),
                       .translated("hola mundo"))
    }

    // MARK: - Recognition error classification

    /// A pause is not a failure. Counting it as one made a meeting with natural silences look
    /// like an unstable session and buried the real failures.
    func testNoSpeechIsNotAFailure() {
        let kind = RecognitionFailureKind.classify(domain: "kAFAssistantErrorDomain", code: 1110)
        XCTAssertEqual(kind, .noSpeech)
        XCTAssertEqual(kind?.sessionEndReason, .noSpeech)
        XCTAssertNotEqual(kind?.sessionEndReason, .error)
    }

    /// We cancel the request ourselves on every rotation; that is not a failure either.
    func testOurOwnCancellationsAreNotFailures() {
        for code in [216, 301] {
            let kind = RecognitionFailureKind.classify(domain: "kAFAssistantErrorDomain", code: code)
            XCTAssertEqual(kind, .cancelled, "code \(code) is a cancellation we caused")
        }
    }

    func testGenuineFailuresAreStillFailures() {
        for code in [203, 1101, 4] {
            let kind = RecognitionFailureKind.classify(domain: "kAFAssistantErrorDomain", code: code)
            XCTAssertEqual(kind, .failure, "code \(code) is a real failure and must stay visible")
        }
    }

    func testUnknownDomainsAreTreatedAsFailures() {
        XCTAssertEqual(RecognitionFailureKind.classify(domain: "NSURLErrorDomain", code: -1009),
                       .failure)
    }

    /// No error at all means the session ended for another reason entirely.
    func testNoErrorClassifiesAsNothing() {
        XCTAssertNil(RecognitionFailureKind.classify(domain: nil, code: nil))
        XCTAssertNil(RecognitionFailureKind.classify(domain: "kAFAssistantErrorDomain", code: nil))
    }
}
