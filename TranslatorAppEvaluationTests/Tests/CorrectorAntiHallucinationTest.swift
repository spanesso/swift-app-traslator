//
//  CorrectorAntiHallucinationTest.swift
//  TranslatorAppEvaluationTests
//
//  SC-007 unit tests for FoundationModelsCorrector anti-hallucination invariants.
//  Runs against fixture cases in Tests/Fixtures/corrector-anti-hallucination-cases.json.
//  Skips on non-A17 Pro devices and on simulators without FoundationModels support.
//

import XCTest
@testable import TranslatorApp

final class CorrectorAntiHallucinationTest: XCTestCase {

    // MARK: - Fixture type

    private struct FixtureCase: Codable {
        let id: String
        let description: String
        let input: String
        let allowedOutput: String
        let disallowedOutput: String?
        let expectation: String
        let lockedTokens: [String]?
    }

    // MARK: - EntityExtractor unit tests (fast, no network/model needed)

    func testEntityExtractorDetectsProperNouns() {
        let entities = EntityExtractor.entities(in: "I work at Apple and meet with Tim Cook")
        XCTAssertTrue(entities.contains("apple") || entities.contains("tim") || entities.contains("cook"),
            "EntityExtractor should detect 'Apple', 'Tim', 'Cook' as entities")
    }

    func testEntityExtractorIgnoresFirstWordCapitalisation() {
        let entities = EntityExtractor.entities(in: "Hello world how are you today")
        XCTAssertFalse(entities.contains("hello"),
            "First word 'Hello' should not be treated as a named entity")
    }

    func testNumeralExtraction() {
        let nums = EntityExtractor.numerals(in: "I need 42 and 3.14 items")
        XCTAssertTrue(nums.contains("42"))
        XCTAssertTrue(nums.contains("3.14"))
    }

    func testHallucinatedNumeralDetection() {
        let hallucinated = EntityExtractor.hallucinatedNumerals(
            reference: "a few days",
            hypothesis: "3 days")
        XCTAssertEqual(hallucinated, ["3"])
    }

    // MARK: - FoundationModelsCorrector (skipped unless iOS 26 + A17 Pro)

    @available(iOS 26.0, *)
    func testAntiHallucinationFixtures() async throws {
        guard DeviceCapabilities.supportsA17Pro else {
            throw XCTSkip("FoundationModelsCorrector requires A17 Pro+")
        }
        let corrector = FoundationModelsCorrector()
        let cases = try loadFixtures()

        for fixture in cases {
            let segment = makeSegment(text: fixture.input, lockedTokens: fixture.lockedTokens ?? [])
            let result = await corrector.correct(segment: segment, lockThreshold: 0.85)

            switch fixture.expectation {
            case "accept":
                XCTAssertNotEqual(result.action, .rejected(reason: nil),
                    "[\(fixture.id)] Expected acceptance but got rejection: \(fixture.description)")
            case "reject", "reject_empty", "reject_if_locked_modified":
                if let disallowed = fixture.disallowedOutput, !disallowed.isEmpty {
                    let outputText = result.segment.text
                    let introducedEntities = EntityExtractor.hallucinatedEntities(
                        reference: fixture.input, hypothesis: outputText)
                    XCTAssertTrue(introducedEntities.isEmpty || result.action == .rejected(reason: nil),
                        "[\(fixture.id)] Corrector should reject output with hallucinated entity: \(fixture.description)")
                }
            default:
                break
            }
        }
    }

    // MARK: - Helpers

    private func loadFixtures() throws -> [FixtureCase] {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "corrector-anti-hallucination-cases",
                                   withExtension: "json",
                                   subdirectory: "Fixtures") else {
            throw XCTSkip("Fixture file not found in bundle")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode([FixtureCase].self, from: Data(contentsOf: url))
    }

    private func makeSegment(text: String, lockedTokens: [String]) -> SpeechSegment {
        let tokens = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.map { word in
            let isLocked = lockedTokens.contains(word.lowercased())
            return TranscriptToken(text: word, confidence: isLocked ? 0.99 : 0.5,
                                   startTime: nil, endTime: nil, isLocked: isLocked)
        }
        return SpeechSegment(text: text, isFinal: true, confidence: 0.75,
                             tokens: tokens, source: .appleSpeechAnalyzer, isHypothesis: false)
    }
}

// Equatable conformance to enable XCTAssertNotEqual on CorrectionAction
extension CorrectionAction: Equatable {
    // synthesised by compiler via associated value Equatable conformance
}
