//
//  NLPSegmenterService.swift
//  TranslatorApp
//

import Foundation
import NaturalLanguage
import OSLog

actor NLPSegmenterService: NLPSegmenterServiceProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Segmenter")

    // Internal rather than private: the timing logic lives in NLPSegmenterService+Timing.swift,
    // and `private` is file-scoped in Swift.
    let stabilityDelayNs: UInt64            = 700_000_000    // 0.7 s — normal
    let stabilityDelayLowQualityNs: UInt64  = 1_200_000_000  // 1.2 s — low-quality ASR
    let stabilityDelayIncompleteNs: UInt64  = 2_500_000_000  // 2.5 s — grammatically open
    let longSentenceWordThreshold = 15
    let minShortPhraseWords = 2
    /// How many words a full stop on a PARTIAL result must close before it is believed.
    /// Below this the period is treated as recogniser noise (see the shredding guard).
    let minWordsForTerminatorEmit = 3
    /// Hard ceiling on how long a pending tail may be withheld (008 FR-014 / SC-013).
    /// Lowered from 6 s: three seconds is the upper bound of a long rhetorical pause, and past
    /// that, holding text back is not waiting — it is losing it.
    let maxPendingIntervalMs = 3_000

    let qualityMetrics: QualityMetricsService
    let telemetry: any PipelineTelemetryProtocol
    var sessionId = "----"

    var committedFullText: String = ""
    var committedWordCount: Int = 0
    /// Last few dozen committed words, kept so overlap trimming never has to look at the whole
    /// meeting. `committedWordCount` remains the authority for position.
    var committedTailWords: [String] = []
    nonisolated static var committedTailLimit: Int { 40 }
    var lastSeenFullText: String = ""
    var pendingStartedAt: ContinuousClock.Instant?
    private var pendingHypothesis: SpeechSegment?
    var currentSegmentConfidence: Float = 1.0
    private var lastSeenGeneration: Int = 0

    /// Refreshed once per ingested segment so the timing path stays synchronous. Reading it
    /// inside `arm(...)` avoids an `await` on the hot path for a value that changes slowly.
    var lastKnownLowQuality = false

    var stabilityTimer: Task<Void, Never>?
    var ceilingTimer: Task<Void, Never>?

    init(qualityMetrics: QualityMetricsService, telemetry: any PipelineTelemetryProtocol) {
        self.qualityMetrics = qualityMetrics
        self.telemetry = telemetry
    }

    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<SegmentedPhrase> {
        AsyncStream { continuation in
            Task {
                await self.resetSession()
                for await segment in stream {
                    await self.ingest(segment, continuation: continuation)
                }
                self.flushTrailing(continuation: continuation)
                continuation.finish()
            }
        }
    }

    // MARK: - Session

    private func resetSession() async {
        sessionId = TelemetrySessionId.new()
        await qualityMetrics.startSession(sessionId: sessionId)
        committedFullText = ""
        committedWordCount = 0
        lastSeenFullText = ""
        committedTailWords.removeAll(keepingCapacity: true)
        pendingStartedAt = nil
        committedTailWords.removeAll(keepingCapacity: true)
        pendingHypothesis = nil
        currentSegmentConfidence = 1.0
        lastSeenGeneration = 0
        lastKnownLowQuality = false
        cancelTimers()
    }

    // MARK: - Ingestion

    private func ingest(_ segment: SpeechSegment,
                        continuation: AsyncStream<SegmentedPhrase>.Continuation) async {
        let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let wordCount = trimmed.split(separator: " ").count
        let isCompleteShort = segment.isFinal || endsWithTerminator(trimmed)

        // Suppress ≤1-word segments only while still partial and open. A complete short
        // utterance ("Yes.", "Okay") must reach the emit path.
        if wordCount < 2 && !isCompleteShort {
            return
        }

        if segment.isHypothesis {
            pendingHypothesis = segment
            return
        }
        pendingHypothesis = nil
        currentSegmentConfidence = segment.confidence
        // Refreshed here, in the async path, so the timing helpers stay synchronous.
        lastKnownLowQuality = await qualityMetrics.isLowQualitySpeech()

        // The recogniser rotated: its transcript restarted from zero, so the committed baseline
        // is no longer comparable. Carried on the segment itself so the reset happens exactly
        // when the first segment of the new generation arrives.
        if segment.sessionGeneration != lastSeenGeneration {
            lastSeenGeneration = segment.sessionGeneration
            telemetry.asrRestartDetected(sessionId,
                                         incomingWords: wordCount,
                                         committedWords: committedWordCount)
            committedFullText = ""
            committedWordCount = 0
            lastSeenFullText = ""
            committedTailWords.removeAll(keepingCapacity: true)
        }

        // ── THE 008 FIX (US3 / FR-013) ────────────────────────────────────────────────────
        // The stability timer used to be cancelled here and four of the paths below returned
        // without ever arming it again. The critical one is the duplicate-text path: while the
        // speaker pauses, SFSpeechRecognizer re-emits the SAME partial repeatedly — that is its
        // normal behaviour — and every repeat cancelled the pending emission. The phrase was
        // then withheld forever and never reached translation. That is symptom S2.
        //
        // Now every early return goes through `reschedule(...)`, which re-arms the timer with
        // the tail that is still pending.
        let fullText = segment.text

        if fullText == lastSeenFullText {
            reschedule(reason: .duplicateText, continuation: continuation)
            return
        }
        lastSeenFullText = fullText

        let pending = pendingSuffix(of: fullText)
        guard !pending.isEmpty else {
            reschedule(reason: .emptyPending, continuation: continuation)
            return
        }

        if pendingStartedAt == nil {
            pendingStartedAt = MonotonicClock.now()
            armCeiling(continuation: continuation)
        }

        let sentences = splitIntoSentences(pending)
        if sentences.count >= 2 {
            for completed in sentences.dropLast() {
                emitIfViable(completed, continuation: continuation, tag: "sentence",
                             confidence: currentSegmentConfidence)
            }
        }

        let tail = pendingSuffix(of: fullText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tail.isEmpty else {
            reschedule(reason: .emptyTail, continuation: continuation)
            return
        }

        // ── SHREDDING GUARD (010 field report) ───────────────────────────────────────────────
        // `segment.isFinal` is a real final result and is trusted unconditionally. A full stop
        // on a PARTIAL is not: with difficult audio, `addsPunctuation` sprinkles periods between
        // words, and forcing an emission on each one turned a conversation into confetti —
        // "It's." "kind." "of." "we need." — one or two words per phrase, each sent off to be
        // translated on its own. A translator given "of." has nothing to work with.
        //
        // Refusing to emit does NOT lose the words: they stay in the pending tail, join what
        // follows, and leave through the stability timer or the 3 s ceiling.
        if segment.isFinal || terminatorCompletesUtterance(tail) {
            cancelTimers()
            emitIfViable(tail, continuation: continuation,
                         tag: segment.isFinal ? "final" : "terminator",
                         confidence: currentSegmentConfidence, forceEmit: true)
            return
        }

        if wordCountOf(tail) > longSentenceWordThreshold, let cut = cutAtLastClauseMarker(tail) {
            let head = cut.head.trimmingCharacters(in: .whitespacesAndNewlines)
            if wordCountOf(head) >= minShortPhraseWords {
                emitIfViable(head, continuation: continuation, tag: "clause",
                             confidence: currentSegmentConfidence)
                reschedule(reason: .newSegment, continuation: continuation)
                return
            }
        }

        arm(tail: tail,
            confidence: currentSegmentConfidence,
            reason: .newSegment,
            continuation: continuation)
    }

    private func flushTrailing(continuation: AsyncStream<SegmentedPhrase>.Continuation) {
        cancelTimers()
        let trailing = pendingSuffix(of: lastSeenFullText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trailing.isEmpty else { return }
        emitIfViable(trailing, continuation: continuation, tag: "flush",
                     confidence: currentSegmentConfidence, forceEmit: true)
    }
}
