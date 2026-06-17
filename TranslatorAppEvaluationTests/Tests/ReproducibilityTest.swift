//
//  ReproducibilityTest.swift
//  TranslatorAppEvaluationTests
//
//  SC-009: Run the same manifest twice through the same engine. Headline
//  WER per accent group must agree within epsilon = 0.05 (5pp absolute).
//  Skips when corpus is absent.
//

import XCTest
@testable import TranslatorApp

final class ReproducibilityTest: XCTestCase {

    private let harness = EvaluationHarness(buildId: "reproducibility")
    private static let epsilon: Double = 0.05

    func testWhisperKitReproducibility() async throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "edacc-subset", withExtension: "json",
                                   subdirectory: "Corpora") else {
            throw XCTSkip("EdAcc corpus not found — skipping reproducibility test")
        }
        let manifest = try EvaluationCorpusManifest.load(from: url)
        let engine = WhisperKitEngine()
        let isReproducible = try await harness.verifyReproducibility(
            manifest: manifest, engine: engine, corrector: nil, epsilon: Self.epsilon)
        XCTAssertTrue(isReproducible,
            "SC-009: WhisperKit WER differed by more than \(Int(Self.epsilon * 100))pp between two runs")
    }

    func testLegacyEngineReproducibility() async throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "edacc-subset", withExtension: "json",
                                   subdirectory: "Corpora") else {
            throw XCTSkip("EdAcc corpus not found — skipping reproducibility test")
        }
        let manifest = try EvaluationCorpusManifest.load(from: url)
        let engine = LegacySFSpeechEngine(listener:
            ContinuousSpeechListener(qualityMetrics: QualityMetricsService()))
        let isReproducible = try await harness.verifyReproducibility(
            manifest: manifest, engine: engine, corrector: nil, epsilon: Self.epsilon)
        XCTAssertTrue(isReproducible,
            "SC-009: LegacySFSpeech WER differed by more than \(Int(Self.epsilon * 100))pp between two runs")
    }
}
