//
//  QualityMetricsService.swift
//  TranslatorApp
//

import Foundation
import OSLog

actor QualityMetricsService {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Quality")

    private var revisionCount: Int = 0
    private var totalRevisions: Int = 0
    private var stabilityDelays: [TimeInterval] = []
    private var wordsPerSecondSamples: [Double] = []
    private var confidenceScores: [Float] = []
    private var fragmentationScores: [Double] = []
    // Per-token histogram added in 005-accent-robust-asr
    private var tokenConfidences: [Float] = []

    private var sessionStartTime: Date?
    private var currentSessionId: String?
    private let maxSamples = 100

    func startSession(sessionId: String) {
        currentSessionId = sessionId
        sessionStartTime = Date()
        revisionCount = 0
        totalRevisions = 0
        stabilityDelays.removeAll()
        wordsPerSecondSamples.removeAll()
        confidenceScores.removeAll()
        fragmentationScores.removeAll()
        tokenConfidences.removeAll()
        logger.info("📊 [Quality] Session started: \(sessionId)")
    }

    func recordRevision(sessionId: String) {
        guard sessionId == currentSessionId else { return }
        revisionCount += 1; totalRevisions += 1
        logger.debug("🔄 [Quality] Revision #\(self.totalRevisions)")
    }

    func recordStabilityDelay(_ delay: TimeInterval, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        stabilityDelays.append(delay)
        if stabilityDelays.count > maxSamples { stabilityDelays.removeFirst() }
    }

    func recordWordsPerSecond(_ wps: Double, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        wordsPerSecondSamples.append(wps)
        if wordsPerSecondSamples.count > maxSamples { wordsPerSecondSamples.removeFirst() }
    }

    func recordConfidence(_ confidence: Float, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        confidenceScores.append(confidence)
        if confidenceScores.count > maxSamples { confidenceScores.removeFirst() }
    }

    func recordFragmentation(_ score: Double, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        fragmentationScores.append(score)
        if fragmentationScores.count > maxSamples { fragmentationScores.removeFirst() }
    }

    // MARK: - Per-token confidence (005-accent-robust-asr)

    func recordTokenConfidences(_ tokens: [TranscriptToken]) {
        let newValues = tokens.map(\.confidence)
        tokenConfidences.append(contentsOf: newValues)
        if tokenConfidences.count > maxSamples * 10 {
            tokenConfidences.removeFirst(newValues.count)
        }
        logger.debug("[Quality] recordTokenConfidences count=\(newValues.count) running=\(self.tokenConfidences.count)")
    }

    var currentConfidenceP10: Float {
        guard !tokenConfidences.isEmpty else { return 0 }
        let sorted = tokenConfidences.sorted()
        let idx = max(0, Int(Double(sorted.count) * 0.10) - 1)
        return sorted[idx]
    }

    var currentConfidenceMedian: Float {
        guard !tokenConfidences.isEmpty else { return 0 }
        let sorted = tokenConfidences.sorted()
        return sorted[sorted.count / 2]
    }

    // MARK: - Snapshot & heuristics

    func getCurrentMetrics() -> QualitySnapshot {
        let avgStability = stabilityDelays.isEmpty ? 0.0 :
            stabilityDelays.reduce(0, +) / Double(stabilityDelays.count)
        let avgWPS = wordsPerSecondSamples.isEmpty ? 0.0 :
            wordsPerSecondSamples.reduce(0, +) / Double(wordsPerSecondSamples.count)
        let avgConf = confidenceScores.isEmpty ? 0.0 :
            confidenceScores.reduce(0, +) / Float(confidenceScores.count)
        let avgFrag = fragmentationScores.isEmpty ? 0.0 :
            fragmentationScores.reduce(0, +) / Double(fragmentationScores.count)
        let duration = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 1.0
        let revRate = Double(totalRevisions) / (duration / 60.0)
        return QualitySnapshot(revisionRate: revRate, avgStabilityDelay: avgStability,
                               avgWordsPerSecond: avgWPS, avgConfidence: avgConf,
                               avgFragmentation: avgFrag, totalRevisions: totalRevisions)
    }

    func isLowQualitySpeech() -> Bool {
        let m = getCurrentMetrics()
        let low = m.revisionRate > 10.0 || m.avgConfidence < 0.6 ||
                  m.avgFragmentation > 0.15 ||
                  m.avgWordsPerSecond < 1.5 || m.avgWordsPerSecond > 4.0
        if low {
            logger.warning("⚠️ [Quality] Low quality | revRate=\(String(format:"%.1f",m.revisionRate)) conf=\(String(format:"%.2f",m.avgConfidence))")
        }
        return low
    }
}
