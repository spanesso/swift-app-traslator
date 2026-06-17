//
//  EvaluationReport.swift
//  TranslatorAppEvaluationTests
//
//  Codable evaluation report produced by EvaluationHarness.run(). One
//  report per (engine, corpus, build) triple. Stored as JSON next to the
//  corpus manifest for reproducibility auditing.
//

import Foundation
@testable import TranslatorApp

struct EvaluationReport: Codable, Sendable {
    let buildId: String
    let runDate: Date
    let engineId: EngineId
    let correctorEnabled: Bool
    let deviceClass: String
    let corpus: String
    let totals: Totals
    let wer: [String: Double]           // AccentGroup.rawValue → WER
    let cer: [String: Double]           // AccentGroup.rawValue → CER
    let intelligibility: Intelligibility?
    let latency: Latency
    let confidenceCalibration: ConfidenceCalibration
    let hallucinatedEntities: HallucinationCounter
    let correctorStats: CorrectorStats?

    // MARK: - Nested types

    struct Totals: Codable, Sendable {
        let items: Int
        let audioSeconds: Double
    }

    struct Intelligibility: Codable, Sendable {
        let rater: String
        let scale: String
        let perGroup: [String: Double]
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
        /// SC-007: zero hallucinated named entities in any single utterance
        var p0Defect: Bool { count > 0 }
    }

    struct CorrectorStats: Codable, Sendable {
        let invocations: Int
        let acceptedEdits: Int
        let rejectedEdits: Int
        var acceptanceRate: Double {
            guard invocations > 0 else { return 0 }
            return Double(acceptedEdits) / Double(invocations)
        }
    }

    // MARK: - Convenience

    func wer(for group: AccentGroup) -> Double? { wer[group.rawValue] }
    func cer(for group: AccentGroup) -> Double? { cer[group.rawValue]  }

    // MARK: - Persistence

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let data = try encoder.encode(self)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) throws -> EvaluationReport {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EvaluationReport.self, from: data)
    }
}
