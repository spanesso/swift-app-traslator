#!/usr/bin/swift
//
//  main.swift — evaluation-delta CLI
//  Usage: swift main.swift <baseline.json> <candidate.json> [--output delta.json]
//
//  Reads two EvaluationReport JSON files, computes SC-001..SC-007 gate results,
//  prints a human-readable summary, and exits 0 if all gates pass or 1 if any fail.
//

import Foundation

// MARK: - Minimal types (mirrored from app; not imported to keep this standalone)

struct Report: Codable {
    let buildId: String
    let engineId: String
    let corpus: String
    let wer: [String: Double]
    struct Latency: Codable { let p50Ms: Double; let p95Ms: Double; let p99Ms: Double }
    let latency: Latency
    struct Confidence: Codable { let spearmanRho: Double }
    let confidenceCalibration: Confidence
    struct Hallucination: Codable { let count: Int }
    let hallucinatedEntities: Hallucination
}

// MARK: - Gates

struct GateResult {
    let name: String; let passed: Bool; let value: String
}

func evaluate(baseline b: Report, candidate c: Report) -> [GateResult] {
    var gates: [GateResult] = []
    let l2Groups = ["italian", "indian_south_asian", "latino"]

    // SC-001: ≥30% rel WER reduction per L2 accent
    for key in l2Groups {
        if let bw = b.wer[key], let cw = c.wer[key], bw > 0 {
            let reduction = (bw - cw) / bw
            gates.append(.init(name: "SC-001 L2 WER reduction (\(key))",
                               passed: reduction >= 0.30,
                               value: String(format: "%.1f%%", reduction * 100)))
        }
    }

    // SC-002: native WER delta ≤ +2pp
    if let bw = b.wer["native"], let cw = c.wer["native"] {
        let delta = cw - bw
        gates.append(.init(name: "SC-002 Native WER regression",
                           passed: delta <= 0.02,
                           value: String(format: "%+.2fpp", delta * 100)))
    }

    // SC-003: p95 latency ≤ 3 000 ms
    gates.append(.init(name: "SC-003 p95 latency",
                       passed: c.latency.p95Ms <= 3000,
                       value: String(format: "%.0f ms", c.latency.p95Ms)))

    // SC-004: Spearman ρ ≥ 0.60
    gates.append(.init(name: "SC-004 Confidence Spearman ρ",
                       passed: c.confidenceCalibration.spearmanRho >= 0.60,
                       value: String(format: "%.3f", c.confidenceCalibration.spearmanRho)))

    // SC-007: zero hallucinated entities
    gates.append(.init(name: "SC-007 Hallucinated entities",
                       passed: c.hallucinatedEntities.count == 0,
                       value: "\(c.hallucinatedEntities.count)"))

    return gates
}

// MARK: - Main

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: evaluation-delta <baseline.json> <candidate.json> [--output delta.json]\n", stderr)
    exit(2)
}

let baselineURL = URL(fileURLWithPath: args[1])
let candidateURL = URL(fileURLWithPath: args[2])
var outputURL: URL? = nil
if let outIdx = args.firstIndex(of: "--output"), args.count > outIdx + 1 {
    outputURL = URL(fileURLWithPath: args[outIdx + 1])
}

let decoder = JSONDecoder()
decoder.keyDecodingStrategy = .convertFromSnakeCase
decoder.dateDecodingStrategy = .iso8601

do {
    let baseline = try decoder.decode(Report.self, from: Data(contentsOf: baselineURL))
    let candidate = try decoder.decode(Report.self, from: Data(contentsOf: candidateURL))
    let gates = evaluate(baseline: baseline, candidate: candidate)

    print("╔═══════════════════════════════════════════════════════════╗")
    print("║  evaluation-delta  baseline=\(baseline.buildId)  candidate=\(candidate.buildId)")
    print("╠═══════════════════════════════════════════════════════════╣")
    for gate in gates {
        let icon = gate.passed ? "✓" : "✗"
        print("║  \(icon)  \(gate.name.padding(toLength: 38, withPad: " ", startingAt: 0)) \(gate.value)")
    }
    let allPassed = gates.allSatisfy(\.passed)
    let verdict = allPassed ? "ACCEPTED" : "REJECTED"
    print("╠═══════════════════════════════════════════════════════════╣")
    print("║  Verdict: \(verdict)")
    print("╚═══════════════════════════════════════════════════════════╝")

    if let outputURL {
        let result: [String: Any] = [
            "baseline": baseline.buildId,
            "candidate": candidate.buildId,
            "verdict": verdict,
            "gates": gates.map { ["name": $0.name, "passed": $0.passed, "value": $0.value] }
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: outputURL, options: .atomic)
    }

    exit(allPassed ? 0 : 1)

} catch {
    fputs("Error: \(error.localizedDescription)\n", stderr)
    exit(2)
}
