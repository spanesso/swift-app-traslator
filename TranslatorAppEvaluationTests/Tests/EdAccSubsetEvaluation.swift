//
//  EdAccSubsetEvaluation.swift
//  TranslatorAppEvaluationTests
//
//  Runs the accent-robustness gates (SC-001, SC-005, SC-006) against a
//  curated subset of the EdAcc corpus. The test SKIPS if the corpus files
//  are not present in the bundle (CI machines without corpus data).
//

import XCTest
@testable import TranslatorApp

final class EdAccSubsetEvaluation: XCTestCase {

    private let harness = EvaluationHarness(buildId: "test-edacc")
    private var manifestURL: URL!

    override func setUpWithError() throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "edacc-subset", withExtension: "json",
                                   subdirectory: "Corpora") else {
            throw XCTSkip("EdAcc corpus not found in bundle — skipping accent evaluation")
        }
        manifestURL = url
    }

    // MARK: - SC-001: ≥30% relative WER reduction for all L2 accents

    func testL2WERReductionVsLegacyBaseline() async throws {
        let manifest = try EvaluationCorpusManifest.load(from: manifestURL)
        let engine = LegacySFSpeechEngine(listener: ContinuousSpeechListener(
            qualityMetrics: QualityMetricsService()))

        let baseline = try await harness.run(manifest: manifest, engine: engine,
                                             corrector: nil, buildId: "legacy-baseline")

        let whisper = WhisperKitEngine()
        let candidate = try await harness.run(manifest: manifest, engine: whisper,
                                              corrector: nil, buildId: "whisperkit")

        let delta = harness.compare(baseline: baseline, candidate: candidate)
        let sc001Gates = delta.gates.filter { $0.name.contains("SC-001") }
        for gate in sc001Gates {
            XCTAssertTrue(gate.passed,
                "\(gate.name): WER reduction \(String(format: "%.1f", gate.value * 100))% below 30% threshold")
        }
    }

    // MARK: - SC-005: Italian accent ≥20% WER reduction

    func testItalianAccentImprovement() async throws {
        let manifest = try EvaluationCorpusManifest.load(from: manifestURL)
        let italianItems = manifest.items.filter { $0.accentGroup == .italian }
        guard !italianItems.isEmpty else { throw XCTSkip("No Italian-accent items in manifest") }

        let legacyPairs = try await transcribePairs(items: italianItems, engine: LegacySFSpeechEngine(
            listener: ContinuousSpeechListener(qualityMetrics: QualityMetricsService())))
        let whisperPairs = try await transcribePairs(items: italianItems, engine: WhisperKitEngine())

        let legacyWER = WERCalculator.batch(legacyPairs).wer
        let whisperWER = WERCalculator.batch(whisperPairs).wer
        let reduction = legacyWER > 0 ? (legacyWER - whisperWER) / legacyWER : 0
        XCTAssertGreaterThanOrEqual(reduction, EvaluationDelta.sc005_minItWERReduction,
            "Italian WER reduction \(String(format: "%.1f", reduction * 100))% below 20% gate")
    }

    // MARK: - SC-006: Indian/South-Asian accent ≥20% WER reduction

    func testIndianAccentImprovement() async throws {
        let manifest = try EvaluationCorpusManifest.load(from: manifestURL)
        let indianItems = manifest.items.filter { $0.accentGroup == .indianSouthAsian }
        guard !indianItems.isEmpty else { throw XCTSkip("No Indian-accent items in manifest") }

        let legacyPairs = try await transcribePairs(items: indianItems, engine: LegacySFSpeechEngine(
            listener: ContinuousSpeechListener(qualityMetrics: QualityMetricsService())))
        let whisperPairs = try await transcribePairs(items: indianItems, engine: WhisperKitEngine())

        let legacyWER = WERCalculator.batch(legacyPairs).wer
        let whisperWER = WERCalculator.batch(whisperPairs).wer
        let reduction = legacyWER > 0 ? (legacyWER - whisperWER) / legacyWER : 0
        XCTAssertGreaterThanOrEqual(reduction, EvaluationDelta.sc006_minHiWERReduction,
            "Indian WER reduction \(String(format: "%.1f", reduction * 100))% below 20% gate")
    }

    // MARK: - Helper

    private func transcribePairs(items: [EvaluationCorpusManifest.Item],
                                 engine: any SpeechEngineProtocol) async throws
        -> [(reference: String, hypothesis: String)] {
        var pairs: [(String, String)] = []
        for item in items {
            let stream = try await engine.start(options: SpeechEngineOptions(requestsTokenDetail: false))
            var hyp = ""
            for await seg in stream { if seg.isFinal { hyp = seg.text } }
            await engine.stop()
            pairs.append((item.referenceTranscript, hyp))
        }
        return pairs
    }
}
