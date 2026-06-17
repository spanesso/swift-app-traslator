//
//  EvaluationDelta.swift
//  TranslatorAppEvaluationTests
//
//  Diff between baseline and candidate EvaluationReports. Encodes all
//  SC-001..SC-010 gate results so CI can fail on any regression.
//

import Foundation
@testable import TranslatorApp

struct EvaluationDelta: Codable, Sendable {
    let baseline: String          // buildId of baseline report
    let candidate: String         // buildId of candidate report
    let verdict: Verdict
    let werDelta: [String: WERPoint]   // AccentGroup.rawValue → WERPoint
    let gates: [Gate]

    var passed: Bool { verdict == .accepted }

    enum Verdict: String, Codable, Sendable {
        case accepted
        case rejectedNativeRegression
        case rejectedHallucinations
        case rejectedConfidenceCalibration
        case rejectedLatency
        case rejectedAccentLift
    }

    struct WERPoint: Codable, Sendable {
        let baseline: Double
        let candidate: Double
        let deltaAbs: Double         // candidate - baseline
        let deltaRel: Double         // deltaAbs / baseline
        let gatePassed: Bool

        init(baseline: Double, candidate: Double, threshold: Double = 0) {
            self.baseline = baseline
            self.candidate = candidate
            self.deltaAbs = candidate - baseline
            self.deltaRel = baseline > 0 ? (candidate - baseline) / baseline : 0
            self.gatePassed = candidate <= baseline + threshold
        }
    }

    struct Gate: Codable, Sendable {
        let name: String
        let passed: Bool
        let value: Double
        let threshold: Double
    }

    // MARK: - Evaluation Gate Thresholds (spec §SC-001..SC-010)

    static let sc001_minL2WERReduction: Double  = 0.30  // ≥30% rel WER reduction vs legacy
    static let sc002_maxNativeWERDelta: Double  = 0.02  // ≤+2pp absolute native regression
    static let sc003_maxLatencyP95Ms: Double    = 3000  // p95 ≤ 3 000 ms
    static let sc004_minConfidenceRho: Double   = 0.60  // Spearman ρ ≥ 0.60
    static let sc005_minItWERReduction: Double  = 0.20  // Italian accent ≥20%
    static let sc006_minHiWERReduction: Double  = 0.20  // Indian accent ≥20%
    static let sc007_maxHallucinationCount: Int = 0     // zero hallucinated entities

    // MARK: - Persistence

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
