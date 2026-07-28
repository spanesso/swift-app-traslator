//
//  QualityMetricsService.swift
//  TranslatorApp
//

import Foundation
import OSLog

actor QualityMetricsService {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Quality")

    private var totalRevisions: Int = 0
    private var stabilityDelays: [TimeInterval] = []
    private var wordsPerSecondSamples: [Double] = []
    private var confidenceScores: [Float] = []
    private var fragmentationScores: [Double] = []
    // Per-token histogram added in 005-accent-robust-asr
    private var tokenConfidences: [Float] = []

    private var sessionStartTime: Date?
    private var currentSessionId: String?
    private var previousTranscript: String = ""
    private var lastTranscriptUpdate: ContinuousClock.Instant?
    private let maxSamples = 100

    func startSession(sessionId: String) {
        currentSessionId = sessionId
        sessionStartTime = Date()
        totalRevisions = 0
        stabilityDelays.removeAll()
        wordsPerSecondSamples.removeAll()
        confidenceScores.removeAll()
        fragmentationScores.removeAll()
        tokenConfidences.removeAll()
        previousTranscript = ""
        lastTranscriptUpdate = nil
        logger.info("📊 [Quality] Session started: \(sessionId)")
    }

    // MARK: - Segment observation

    /// Records every quality signal derivable from one ASR update.
    ///
    /// 008 fix: this used to live in the speech listener, which passed ITS session id while the
    /// session was opened by the segmenter with a different UUID. The `sessionId == current`
    /// guard therefore never matched and every revision, stability, words-per-second and
    /// fragmentation sample was silently discarded — leaving `isLowQualitySpeech()` deciding on
    /// almost no data. Recording now happens where the segments actually flow, against whatever
    /// session is open.
    func recordSegmentObservation(text: String, isFinal: Bool, confidence: Float) {
        guard currentSessionId != nil else { return }
        let now = MonotonicClock.now()

        // A "revision" is the recogniser CHANGING what it already said — not simply sending
        // another partial. Counting every partial produced rates around 180/min against a
        // threshold of 10, so every session was classified low quality and the emission delay
        // was permanently pinned at 1 200 ms. Comparison ignores case and punctuation because
        // `addsPunctuation` rewrites both on nearly every update without changing the words.
        if !previousTranscript.isEmpty, !Self.isContinuation(of: previousTranscript, in: text) {
            totalRevisions += 1
        }

        if let last = lastTranscriptUpdate {
            let elapsedSeconds = Double(MonotonicClock.milliseconds(from: last, to: now)) / 1000.0
            append(&stabilityDelays, elapsedSeconds)
            let words = text.split(separator: " ").count
            if elapsedSeconds > 0, words > 0 {
                append(&wordsPerSecondSamples, Double(words) / elapsedSeconds)
            }
        }

        // Partial results report 0.0 confidence; averaging those in drags the session below the
        // low-quality threshold for no reason. Only finals carry real per-segment confidence.
        if isFinal {
            append(&confidenceScores, confidence)
        }
        append(&fragmentationScores, Self.fragmentation(of: text))

        previousTranscript = text
        lastTranscriptUpdate = now
    }

    func recordTokenConfidences(_ tokens: [TranscriptToken]) {
        let newValues = tokens.map(\.confidence)
        tokenConfidences.append(contentsOf: newValues)
        if tokenConfidences.count > maxSamples * 10 {
            tokenConfidences.removeFirst(newValues.count)
        }
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
        let duration = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 1.0
        return QualitySnapshot(revisionRate: Double(totalRevisions) / max(duration / 60.0, 0.01),
                               avgStabilityDelay: average(stabilityDelays),
                               avgWordsPerSecond: average(wordsPerSecondSamples),
                               avgConfidence: averageFloat(confidenceScores),
                               avgFragmentation: average(fragmentationScores),
                               totalRevisions: totalRevisions)
    }

    /// Drives the segmenter's adaptive stability delay.
    ///
    /// 008 fix (FR-015): speaking rate was removed from this decision. A fast speaker
    /// (`avgWordsPerSecond > 4.0`) used to be classified as low quality, which raised the
    /// emission threshold from 700 ms to 1 200 ms — slowing down emission at exactly the moment
    /// it needed to speed up, and contributing to the "fast speech loses fragments" report.
    /// Rate is a property of the speaker; it is not evidence of poor recognition.
    func isLowQualitySpeech() -> Bool {
        let m = getCurrentMetrics()
        let hasConfidenceData = !confidenceScores.isEmpty
        let low = m.revisionRate > 10.0 ||
                  (hasConfidenceData && m.avgConfidence < 0.6) ||
                  m.avgFragmentation > 0.15
        if low {
            logger.warning("""
                ⚠️ [Quality] Low quality | revRate=\(String(format: "%.1f", m.revisionRate)) \
                conf=\(String(format: "%.2f", m.avgConfidence)) \
                frag=\(String(format: "%.2f", m.avgFragmentation))
                """)
        }
        return low
    }

    // MARK: - Helpers

    private func append<T>(_ samples: inout [T], _ value: T) {
        samples.append(value)
        if samples.count > maxSamples { samples.removeFirst() }
    }

    private func average(_ values: [Double]) -> Double {
        values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func averageFloat(_ values: [Float]) -> Float {
        values.isEmpty ? 0 : values.reduce(0, +) / Float(values.count)
    }

    /// True when `text` merely extends `previous` — the recogniser appending, not rethinking.
    private static func isContinuation(of previous: String, in text: String) -> Bool {
        let previousWords = normalizedWords(previous)
        let currentWords = normalizedWords(text)
        guard currentWords.count >= previousWords.count else { return false }
        return Array(currentWords.prefix(previousWords.count)) == previousWords
    }

    private static func normalizedWords(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    private static func fragmentation(of text: String) -> Double {
        let words = text.split(separator: " ")
        guard words.count > 1 else { return 0.0 }
        let commonShortWords: Set<String> = ["a", "i", "an", "to", "in", "on", "is", "it", "he", "we"]
        var fragmentCount = 0
        for word in words where word.count <= 2 && !commonShortWords.contains(word.lowercased()) {
            fragmentCount += 1
        }
        for i in 0..<(words.count - 1) where words[i].lowercased() == words[i + 1].lowercased() {
            fragmentCount += 1
        }
        return Double(fragmentCount) / Double(words.count)
    }
}
