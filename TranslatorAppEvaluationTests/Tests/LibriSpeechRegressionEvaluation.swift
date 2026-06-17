//
//  LibriSpeechRegressionEvaluation.swift
//  TranslatorAppEvaluationTests
//
//  SC-002 regression guard: WhisperKit must NOT degrade native English
//  (US accent) WER by more than 2pp absolute vs the LegacySFSpeech baseline.
//  Uses the LibriSpeech test-clean subset in Corpora/librispeech-subset.json.
//

import XCTest
@testable import TranslatorApp

final class LibriSpeechRegressionEvaluation: XCTestCase {

    private let harness = EvaluationHarness(buildId: "librispeech-regression")

    func testNativeEnglishWERRegression() async throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "librispeech-subset", withExtension: "json",
                                   subdirectory: "Corpora") else {
            throw XCTSkip("LibriSpeech corpus not found — skipping native regression test")
        }
        let manifest = try EvaluationCorpusManifest.load(from: url)

        let legacyEngine = LegacySFSpeechEngine(listener:
            ContinuousSpeechListener(qualityMetrics: QualityMetricsService()))
        let baseline = try await harness.run(manifest: manifest, engine: legacyEngine,
                                             corrector: nil, buildId: "legacy")

        let whisper = WhisperKitEngine()
        let candidate = try await harness.run(manifest: manifest, engine: whisper,
                                              corrector: nil, buildId: "whisper")

        let delta = harness.compare(baseline: baseline, candidate: candidate)
        let sc002 = delta.gates.first { $0.name.contains("SC-002") }
        XCTAssertNotNil(sc002, "SC-002 gate missing from delta")
        XCTAssertTrue(sc002?.passed ?? false,
            "SC-002 FAILED: native WER increased by \(String(format: "%.2f", (sc002?.value ?? 0) * 100))pp (max 2pp)")
    }

    // MARK: - SC-003 latency sanity check on a small native-English set

    func testFirstTokenLatencyP95() async throws {
        let bundle = Bundle(for: Self.self)
        guard let url = bundle.url(forResource: "librispeech-subset", withExtension: "json",
                                   subdirectory: "Corpora") else {
            throw XCTSkip("LibriSpeech corpus not found — skipping latency test")
        }
        let manifest = try EvaluationCorpusManifest.load(from: url)
        let whisper = WhisperKitEngine()
        let report = try await harness.run(manifest: manifest, engine: whisper,
                                           corrector: nil, buildId: "latency-check")
        XCTAssertLessThanOrEqual(report.latency.p95Ms, EvaluationDelta.sc003_maxLatencyP95Ms,
            "SC-003 FAILED: p95 latency \(Int(report.latency.p95Ms)) ms exceeds 3 000 ms")
    }
}
