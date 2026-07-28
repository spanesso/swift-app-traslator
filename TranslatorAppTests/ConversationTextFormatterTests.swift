//
//  ConversationTextFormatterTests.swift
//  TranslatorAppTests
//
//  The five invariants and six mandatory cases from contracts/ConversationTextFormatter.swift
//  (008-fix-audio-pipeline-resilience, US7).
//
//  I1 is the one that matters: equal line counts in both blocks. That is what makes a missing
//  translation an auditable marker instead of a silent hole.
//

import XCTest
@testable import TranslatorApp

final class ConversationTextFormatterTests: XCTestCase {

    private func fragment(_ id: Int, _ source: String, _ outcome: TranslationOutcome) -> ConversationFragment {
        ConversationFragment(id: id, sourceText: source, translation: outcome, sourceConfidence: 1.0)
    }

    // MARK: - I1 / SC-020 — equal line counts, always

    func testAllTranslatedProducesEqualLineCounts() {
        let fragments = (0..<20).map { fragment($0, "english \($0)", .translated("spanish \($0)")) }
        let english = ConversationTextFormatter.englishBlock(fragments)
        let spanish = ConversationTextFormatter.spanishBlock(fragments)
        XCTAssertEqual(ConversationTextFormatter.lineCount(english), 20)
        XCTAssertEqual(ConversationTextFormatter.lineCount(spanish), 20)
        XCTAssertTrue(ConversationTextFormatter.linesAreAligned(english: english, spanish: spanish))
    }

    // Case 2 — one translation failed. THE S5 BUG: the line used to vanish entirely.
    func testOneFailedTranslationKeepsItsLine() {
        var fragments = (0..<5).map { fragment($0, "english \($0)", .translated("spanish \($0)")) }
        fragments[2].translation = .unavailable(.failed)

        let english = ConversationTextFormatter.englishBlock(fragments)
        let spanish = ConversationTextFormatter.spanishBlock(fragments)

        XCTAssertEqual(ConversationTextFormatter.lineCount(english), 5)
        XCTAssertEqual(ConversationTextFormatter.lineCount(spanish), 5)
        let spanishLines = spanish.components(separatedBy: "\n")
        XCTAssertTrue(spanishLines[2].contains("no disponible"))
        XCTAssertFalse(spanishLines[2].isEmpty, "I2: the marker line must never be empty")
        // Alignment intact: line 3 still pairs with line 3.
        XCTAssertEqual(spanishLines[3], "spanish 3")
    }

    // Case 3 — the translation service never started; every fragment resolves to a marker.
    func testWholeSessionUnavailableStillAligns() {
        let fragments = (0..<8).map { fragment($0, "english \($0)", .unavailable(.serviceUnavailable)) }
        let english = ConversationTextFormatter.englishBlock(fragments)
        let spanish = ConversationTextFormatter.spanishBlock(fragments)
        XCTAssertEqual(ConversationTextFormatter.lineCount(english), 8)
        XCTAssertEqual(ConversationTextFormatter.lineCount(spanish), 8)
    }

    // Case 4 — THE SEPARATOR TRAP. A fragment containing newlines must still be one line.
    func testInternalNewlinesDoNotBreakLineCount() {
        let fragments = [
            fragment(0, "first line\nsecond line", .translated("primera\nsegunda")),
            fragment(1, "plain", .translated("simple"))
        ]
        let english = ConversationTextFormatter.englishBlock(fragments)
        let spanish = ConversationTextFormatter.spanishBlock(fragments)
        XCTAssertEqual(ConversationTextFormatter.lineCount(english), 2)
        XCTAssertEqual(ConversationTextFormatter.lineCount(spanish), 2)
        XCTAssertTrue(ConversationTextFormatter.linesAreAligned(english: english, spanish: spanish))
    }

    // Case 5 — no fragments.
    func testEmptyInputProducesEmptyBlocks() {
        XCTAssertEqual(ConversationTextFormatter.englishBlock([]), "")
        XCTAssertEqual(ConversationTextFormatter.spanishBlock([]), "")
        XCTAssertEqual(ConversationTextFormatter.lineCount(""), 0)
    }

    // I3 — a pending fragment must not silently vanish if it ever reaches the formatter.
    func testPendingFragmentStillOccupiesALine() {
        let fragments = [fragment(0, "english", .pending)]
        let spanish = ConversationTextFormatter.spanishBlock(fragments)
        XCTAssertEqual(ConversationTextFormatter.lineCount(spanish), 1)
        XCTAssertFalse(spanish.isEmpty)
    }

    // I5 — deterministic output.
    func testExportDocumentIsDeterministic() {
        let fragments = (0..<3).map { fragment($0, "en \($0)", .translated("es \($0)")) }
        XCTAssertEqual(ConversationTextFormatter.exportDocument(fragments),
                       ConversationTextFormatter.exportDocument(fragments))
    }

    func testExportDocumentContainsBothHeaders() {
        let document = ConversationTextFormatter.exportDocument([fragment(0, "a", .translated("b"))])
        XCTAssertTrue(document.contains(ConversationTextFormatter.englishHeader))
        XCTAssertTrue(document.contains(ConversationTextFormatter.spanishHeader))
    }

    // Case 6 — pre-008 documents open and export without error, with no inferred pairing.
    func testLegacyFormatIsDetectedNotRepaired() {
        // English joined with spaces (one line), Spanish with newlines (three lines).
        let legacyEnglish = "one two three"
        let legacySpanish = "uno\ndos\ntres"
        XCTAssertTrue(ConversationTextFormatter.isLegacyFormat(english: legacyEnglish,
                                                              spanish: legacySpanish))
        let document = ConversationTextFormatter.exportDocument(english: legacyEnglish,
                                                                spanish: legacySpanish)
        XCTAssertTrue(document.contains("one two three"))
        XCTAssertTrue(document.contains("uno"))
    }

    func testAlignedDocumentIsNotFlaggedAsLegacy() {
        XCTAssertFalse(ConversationTextFormatter.isLegacyFormat(english: "a\nb", spanish: "x\ny"))
    }

    func testPlaceholdersWhenSideIsEmpty() {
        let document = ConversationTextFormatter.exportDocument(english: "", spanish: "")
        XCTAssertTrue(document.contains("(no transcript)"))
        XCTAssertTrue(document.contains("(no translation)"))
    }
}
