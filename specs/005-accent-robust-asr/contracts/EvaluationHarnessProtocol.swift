//
//  EvaluationHarnessProtocol.swift
//  TranslatorApp — feature 005-accent-robust-asr
//  TEST TARGET ONLY — NOT shipped in the production binary.
//
//  Drives the live pipeline (engine + corrector + translator) against a labeled
//  corpus and emits the numeric report the spec's SC-001..SC-010 are judged against.
//

import Foundation

protocol EvaluationHarnessProtocol: Sendable {
    /// Run the full live pipeline against every item in `manifest`,
    /// using the supplied engine + (optional) corrector + translator adapter.
    ///
    /// The harness MUST use the same code paths the shipping app uses — no
    /// shortcuts, no engine mocks. Audio is fed in real time (not faster) so
    /// latency measurements are valid.
    func run(manifest: EvaluationCorpusManifest,
             engine: SpeechEngineProtocol,
             corrector: TranscriptCorrectorProtocol?,
             buildId: String) async throws -> EvaluationReport

    /// Compare two reports and produce a delta with pass/fail gates per Success Criterion.
    func compare(baseline: EvaluationReport,
                 candidate: EvaluationReport) -> EvaluationDelta

    /// Reproducibility check — run the same engine on the same manifest twice
    /// and verify headline metrics agree within `epsilon` (SC-009).
    func verifyReproducibility(manifest: EvaluationCorpusManifest,
                               engine: SpeechEngineProtocol,
                               corrector: TranscriptCorrectorProtocol?,
                               epsilon: Double) async throws -> Bool
}

/// Codable manifest type — full JSON shape in `data-model.md` §3.1.
struct EvaluationCorpusManifest: Codable, Sendable {
    let name: String
    let license: String
    let items: [Item]

    struct Item: Codable, Sendable {
        let id: String
        let audioPath: String           // relative to the manifest's directory
        let referenceTranscript: String
        let accentGroup: AccentGroup
        let speakerId: String
        let durationSeconds: Double
    }
}

/// Codable report — full JSON shape in `data-model.md` §3.2.
struct EvaluationReport: Codable, Sendable {
    let buildId: String
    let runDate: Date
    let engineId: EngineId
    let correctorEnabled: Bool
    let deviceClass: String
    let corpus: String
    let totals: Totals
    let wer: [AccentGroup: Double]
    let cer: [AccentGroup: Double]
    let intelligibility: Intelligibility?     // nil when no human raters yet
    let latency: Latency
    let confidenceCalibration: ConfidenceCalibration
    let hallucinatedEntities: HallucinationCounter
    let correctorStats: CorrectorStats?

    struct Totals: Codable, Sendable {
        let items: Int
        let audioSeconds: Double
    }
    struct Intelligibility: Codable, Sendable {
        let rater: String
        let scale: String
        let perGroup: [AccentGroup: Double]
    }
    struct Latency: Codable, Sendable {
        let p50Ms: Double
        let p95Ms: Double
        let p99Ms: Double
    }
    struct ConfidenceCalibration: Codable, Sendable {
        let spearmanRho: Double
    }
    struct HallucinationCounter: Codable, Sendable {
        let count: Int
        let p0Defect: Bool
    }
    struct CorrectorStats: Codable, Sendable {
        let invocations: Int
        let acceptedEdits: Int
        let rejectedEdits: Int
    }
}

/// Codable delta — full JSON shape in `data-model.md` §3.3.
struct EvaluationDelta: Codable, Sendable {
    let baseline: String
    let candidate: String
    let verdict: Verdict
    let werDelta: [AccentGroup: WERPoint]
    let gates: [Gate]

    enum Verdict: String, Codable, Sendable {
        case accepted
        case rejectedNativeRegression
        case rejectedHallucinations
        case rejectedConfidenceCalibration
        case rejectedLatency
        case rejectedAccentLift
    }

    struct WERPoint: Codable, Sendable {
        let a: Double
        let b: Double
        let deltaAbs: Double
        let deltaRel: Double
        let gatePassed: Bool
    }

    struct Gate: Codable, Sendable {
        let name: String           // e.g. "SC-001 ≥30% rel L2 reduction"
        let passed: Bool
        let value: Double
    }
}
