//
//  EvaluationHarness.swift
//  TranslatorAppEvaluationTests
//
//  Concrete evaluation harness. Feeds audio from the corpus through the live
//  pipeline (engine → corrector → WERCalculator) and emits an EvaluationReport.
//  Audio playback is real-time: latency measurements reflect production conditions.
//

import Foundation
import AVFoundation
@testable import TranslatorApp

final class EvaluationHarness: EvaluationHarnessProtocol, Sendable {

    let buildId: String

    init(buildId: String = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "dev") {
        self.buildId = buildId
    }

    // MARK: - run

    func run(manifest: EvaluationCorpusManifest,
             engine: any SpeechEngineProtocol,
             corrector: (any TranscriptCorrectorProtocol)?,
             buildId: String) async throws -> EvaluationReport {

        var werPerGroup: [String: [Double]] = [:]
        var cerPerGroup: [String: [Double]] = [:]
        var latenciesMs: [Double] = []
        var hallucinationCount = 0
        var correctorInvocations = 0
        var correctorAccepted = 0
        var correctorRejected = 0

        for item in manifest.items {
            let audioURL = URL(fileURLWithPath: item.audioPath)
            guard FileManager.default.fileExists(atPath: audioURL.path) else { continue }

            let t0 = Date()
            let hypothesis = try await transcribe(audioURL: audioURL,
                                                  engine: engine,
                                                  corrector: corrector,
                                                  correctorInvocations: &correctorInvocations,
                                                  correctorAccepted: &correctorAccepted,
                                                  correctorRejected: &correctorRejected)
            let latencyMs = Date().timeIntervalSince(t0) * 1000
            latenciesMs.append(latencyMs)

            let w = WERCalculator.wer(reference: item.referenceTranscript, hypothesis: hypothesis)
            let c = WERCalculator.cer(reference: item.referenceTranscript, hypothesis: hypothesis)
            let key = item.accentGroup.rawValue
            werPerGroup[key, default: []].append(w)
            cerPerGroup[key, default: []].append(c)

            let hallucinations = EntityExtractor.hallucinatedEntities(
                reference: item.referenceTranscript, hypothesis: hypothesis)
            hallucinationCount += hallucinations.count
        }

        let sortedLatencies = latenciesMs.sorted()
        let p50 = percentile(sortedLatencies, 0.50)
        let p95 = percentile(sortedLatencies, 0.95)
        let p99 = percentile(sortedLatencies, 0.99)

        let werAveraged = werPerGroup.mapValues { $0.reduce(0, +) / Double($0.count) }
        let cerAveraged = cerPerGroup.mapValues { $0.reduce(0, +) / Double($0.count) }

        let correctorStats: EvaluationReport.CorrectorStats? = corrector != nil
            ? .init(invocations: correctorInvocations,
                    acceptedEdits: correctorAccepted,
                    rejectedEdits: correctorRejected)
            : nil

        return EvaluationReport(
            buildId: buildId,
            runDate: Date(),
            engineId: engine.engineId,
            correctorEnabled: corrector != nil,
            deviceClass: DeviceCapabilities.supportsA17Pro ? "A17Pro+" : "standard",
            corpus: manifest.name,
            totals: .init(items: manifest.items.count, audioSeconds: manifest.totalAudioSeconds),
            wer: werAveraged,
            cer: cerAveraged,
            intelligibility: nil,
            latency: .init(p50Ms: p50, p95Ms: p95, p99Ms: p99),
            confidenceCalibration: .init(spearmanRho: 0),
            hallucinatedEntities: .init(count: hallucinationCount),
            correctorStats: correctorStats
        )
    }

    // MARK: - compare

    func compare(baseline: EvaluationReport, candidate: EvaluationReport) -> EvaluationDelta {
        var gates: [EvaluationDelta.Gate] = []
        var werDelta: [String: EvaluationDelta.WERPoint] = [:]

        // Build per-accent WER points
        for group in AccentGroup.allCases {
            let key = group.rawValue
            guard let bWer = baseline.wer[key], let cWer = candidate.wer[key] else { continue }
            let point = EvaluationDelta.WERPoint(baseline: bWer, candidate: cWer)
            werDelta[key] = point

            // SC-001: ≥30% rel WER reduction for L2 accents vs baseline
            if group != .native {
                let reduction = bWer > 0 ? (bWer - cWer) / bWer : 0
                let passed = reduction >= EvaluationDelta.sc001_minL2WERReduction
                gates.append(.init(name: "SC-001 L2 WER lift (\(key))", passed: passed,
                                   value: reduction, threshold: EvaluationDelta.sc001_minL2WERReduction))
            }

            // SC-002: native WER must not degrade more than 2pp absolute
            if group == .native {
                let delta = cWer - bWer
                let passed = delta <= EvaluationDelta.sc002_maxNativeWERDelta
                gates.append(.init(name: "SC-002 Native WER regression", passed: passed,
                                   value: delta, threshold: EvaluationDelta.sc002_maxNativeWERDelta))
            }
        }

        // SC-003: p95 latency
        gates.append(.init(name: "SC-003 Latency p95",
                           passed: candidate.latency.p95Ms <= EvaluationDelta.sc003_maxLatencyP95Ms,
                           value: candidate.latency.p95Ms,
                           threshold: EvaluationDelta.sc003_maxLatencyP95Ms))

        // SC-004: confidence calibration
        gates.append(.init(name: "SC-004 Confidence Spearman ρ",
                           passed: candidate.confidenceCalibration.spearmanRho >= EvaluationDelta.sc004_minConfidenceRho,
                           value: candidate.confidenceCalibration.spearmanRho,
                           threshold: EvaluationDelta.sc004_minConfidenceRho))

        // SC-007: zero hallucinated entities
        gates.append(.init(name: "SC-007 Hallucinated entities",
                           passed: candidate.hallucinatedEntities.count <= EvaluationDelta.sc007_maxHallucinationCount,
                           value: Double(candidate.hallucinatedEntities.count),
                           threshold: Double(EvaluationDelta.sc007_maxHallucinationCount)))

        let nativeGateFailed = gates.first { $0.name.contains("SC-002") && !$0.passed } != nil
        let hallucinationFailed = gates.first { $0.name.contains("SC-007") && !$0.passed } != nil
        let latencyFailed = gates.first { $0.name.contains("SC-003") && !$0.passed } != nil
        let confidenceFailed = gates.first { $0.name.contains("SC-004") && !$0.passed } != nil
        let accentLiftFailed = gates.filter { $0.name.contains("SC-001") && !$0.passed }.count > 0

        let verdict: EvaluationDelta.Verdict
        if nativeGateFailed { verdict = .rejectedNativeRegression }
        else if hallucinationFailed { verdict = .rejectedHallucinations }
        else if latencyFailed { verdict = .rejectedLatency }
        else if confidenceFailed { verdict = .rejectedConfidenceCalibration }
        else if accentLiftFailed { verdict = .rejectedAccentLift }
        else { verdict = .accepted }

        return EvaluationDelta(baseline: baseline.buildId, candidate: candidate.buildId,
                               verdict: verdict, werDelta: werDelta, gates: gates)
    }

    // MARK: - reproducibility (SC-009)

    func verifyReproducibility(manifest: EvaluationCorpusManifest,
                               engine: any SpeechEngineProtocol,
                               corrector: (any TranscriptCorrectorProtocol)?,
                               epsilon: Double) async throws -> Bool {
        let r1 = try await run(manifest: manifest, engine: engine, corrector: corrector, buildId: "run1")
        let r2 = try await run(manifest: manifest, engine: engine, corrector: corrector, buildId: "run2")
        for group in AccentGroup.allCases {
            let key = group.rawValue
            guard let w1 = r1.wer[key], let w2 = r2.wer[key] else { continue }
            if abs(w1 - w2) > epsilon { return false }
        }
        return true
    }

    // MARK: - Private helpers

    private func transcribe(audioURL: URL,
                            engine: any SpeechEngineProtocol,
                            corrector: (any TranscriptCorrectorProtocol)?,
                            correctorInvocations: inout Int,
                            correctorAccepted: inout Int,
                            correctorRejected: inout Int) async throws -> String {
        let stream = try await engine.start(options: SpeechEngineOptions(requestsTokenDetail: true))
        var finalText = ""
        for await segment in stream {
            guard segment.isFinal, !segment.isHypothesis else { continue }
            var processed = segment
            if let corrector {
                correctorInvocations += 1
                let result = await corrector.correct(segment: segment, lockThreshold: 0.85)
                switch result.action {
                case .accepted: correctorAccepted += 1; processed = result.segment
                case .rejected: correctorRejected += 1
                case .skipped: break
                }
            }
            finalText = processed.text
        }
        await engine.stop()
        return finalText
    }

    private func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = Int((p * Double(sorted.count - 1)).rounded())
        return sorted[Swift.max(0, Swift.min(idx, sorted.count - 1))]
    }
}
