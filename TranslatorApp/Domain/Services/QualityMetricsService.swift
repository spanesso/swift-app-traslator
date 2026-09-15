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
    /// The current verdict. It is also the hysteresis state — which threshold applies depends on
    /// it — so it must be updated on every call, not only when it is logged.
    private var isCurrentlyLowQuality = false
    /// Counted separately from the sample arrays, which are capped and would saturate.
    private var observationCount = 0
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
        isCurrentlyLowQuality = false
        observationCount = 0
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
        observationCount += 1

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

    // MARK: - Calibration
    //
    // Numbers from field traces of real multi-speaker meetings on on-device recognition.
    //
    // The original ceiling of 10 revisions/min classified EVERY session as low quality: a
    // meeting that is working sits around 35/min, because `addsPunctuation` keeps rewording
    // what it already said. That was not cosmetic — it pinned the emission delay at 1 200 ms
    // for the whole session, so the 700 ms path never ran and a pause between two speakers was
    // never short enough to release the phrase.

    /// It takes this to be called low quality…
    nonisolated static var enterLowRevisionRate: Double { 45.0 }
    /// …and it stays low until it comes back under this. The gap is deliberate: with a single
    /// threshold at the operating point the verdict flipped on every crossing — a trace showed
    /// 34.4 → 36.5 → 34.7 within a minute — and each flip moved the emission delay between
    /// 700 ms and 1 200 ms for a change no speaker would recognise as a change.
    nonisolated static var leaveLowRevisionRate: Double { 35.0 }
    nonisolated static var fragmentationCeiling: Double { 0.15 }

    /// No verdict before the session has produced something to judge.
    ///
    /// `revisionRate` divides by the elapsed session time, so two seconds in, ONE revision reads
    /// as 30/min. Field traces opened every meeting with `revRate=85.0` and a LOW verdict built
    /// on noise — which put the slowest emission delay exactly where the first phrases arrive.
    nonisolated static var warmUpSeconds: Double { 20 }
    nonisolated static var warmUpObservations: Int { 25 }

    /// The verdict itself, as a pure function of the evidence and the previous verdict.
    ///
    /// Separated from the actor so the calibration can be tested directly, without a session,
    /// a clock, or a stream of fake partials.
    ///
    /// `confidence` is nil whenever no final result has carried one — which on iOS 26 on-device
    /// recognition means the whole meeting, since `isFinal` effectively never fires. The term is
    /// kept for engines that do report finals; do not read the expression as if all three
    /// signals were live on this platform.
    nonisolated static func classify(revisionRate: Double,
                                     fragmentation: Double,
                                     confidence: Float?,
                                     wasLow: Bool) -> Bool {
        let revisionCeiling = wasLow ? leaveLowRevisionRate : enterLowRevisionRate
        if revisionRate > revisionCeiling { return true }
        if let confidence, confidence < 0.6 { return true }
        return fragmentation > fragmentationCeiling
    }

    /// Drives the segmenter's adaptive stability delay.
    ///
    /// 008 fix (FR-015): speaking rate was removed from this decision. A fast speaker
    /// (`avgWordsPerSecond > 4.0`) used to be classified as low quality, which raised the
    /// emission threshold from 700 ms to 1 200 ms — slowing down emission at exactly the moment
    /// it needed to speed up, and contributing to the "fast speech loses fragments" report.
    /// Rate is a property of the speaker; it is not evidence of poor recognition.
    func isLowQualitySpeech() -> Bool {
        guard hasEnoughEvidenceToJudge else {
            report(false, snapshot: nil)
            return false
        }
        let m = getCurrentMetrics()
        let low = Self.classify(revisionRate: m.revisionRate,
                                fragmentation: m.avgFragmentation,
                                confidence: confidenceScores.isEmpty ? nil : m.avgConfidence,
                                wasLow: isCurrentlyLowQuality)
        report(low, snapshot: m)
        return low
    }

    private var hasEnoughEvidenceToJudge: Bool {
        guard observationCount >= Self.warmUpObservations else { return false }
        guard let startedAt = sessionStartTime else { return false }
        return Date().timeIntervalSince(startedAt) >= Self.warmUpSeconds
    }

    /// Logs only on a change of verdict. This used to log on every partial — three lines a
    /// second for the whole meeting — which buried every other event in the trace.
    private func report(_ low: Bool, snapshot: QualitySnapshot?) {
        guard low != isCurrentlyLowQuality else { return }
        isCurrentlyLowQuality = low
        guard let m = snapshot else {
            logger.notice("📊 [Quality] OK | warming up")
            return
        }
        logger.notice("""
            📊 [Quality] \(low ? "LOW" : "OK") | revRate=\(String(format: "%.1f", m.revisionRate)) \
            conf=\(String(format: "%.2f", m.avgConfidence)) \
            frag=\(String(format: "%.2f", m.avgFragmentation))
            """)
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
