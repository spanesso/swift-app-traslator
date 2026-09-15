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

    var committedWordCount: Int = 0
    /// How far back to read the recogniser's cumulative text. ~60 s of speech, far more than a
    /// pending tail can legitimately reach given the 3 s emission ceiling.
    nonisolated static var pendingScanWindow: Int { 200 }
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

    /// Consecutive updates in which the committed text could not be located in the recogniser's
    /// window. Bounded, because the alternative was a permanent stall — see `pendingSuffix`.
    var anchorMisses = 0
    nonisolated static var maxAnchorMisses: Int { 3 }

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
        committedWordCount = 0
        lastSeenFullText = ""
        committedTailWords.removeAll(keepingCapacity: true)
        pendingStartedAt = nil
        pendingHypothesis = nil
        currentSegmentConfidence = 1.0
        lastSeenGeneration = 0
        lastKnownLowQuality = false
        anchorMisses = 0
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
            // What was still pending belongs to the transcript that just ended. It used to be
            // dropped here: the baseline was reset without emitting it, and the armed timer then
            // compared against the NEW transcript and never matched (research 2026-09-15, P4).
            flushBeforeRestart(continuation: continuation)
            committedWordCount = 0
            lastSeenFullText = ""
            // KEPT, exactly as on the unsignalled-restart path below. The new request is fed the
            // most recent audio again, so its first words repeat the end of what was committed;
            // clearing this showed them twice (D3).
            pendingStartedAt = nil
            anchorMisses = 0
            cancelTimers()
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

        // ── THE UTTERANCE BOUNDARY (field logs, multi-speaker meeting) ───────────────────────
        // On iOS 26 the on-device recogniser restarts its transcript at an utterance boundary
        // WITHOUT reporting a final result and without ending the task — so `sessionGeneration`
        // does not change and the check above cannot see it. The baseline then pointed into a
        // string that no longer existed: `pendingSuffix` returned nothing, the phrase already on
        // the pending tail was stranded, and the next speaker's first words waited for the 3 s
        // ceiling before anyone saw them.
        //
        // A restart is also the one moment we KNOW an utterance is over, so the pending tail is
        // emitted here instead of being held for a timer that no longer has anything to wait for.
        if Self.didRestartTranscript(previous: lastSeenFullText, incoming: fullText) {
            telemetry.asrRestartDetected(sessionId,
                                         incomingWords: wordCountOf(fullText),
                                         committedWords: committedWordCount)
            flushBeforeRestart(continuation: continuation)
            committedWordCount = 0
            // `committedTailWords` is deliberately KEPT: the new transcript often repeats the
            // words spoken across the boundary, and this is what stops them being shown twice.
            pendingStartedAt = nil
            anchorMisses = 0
            cancelTimers()
        }

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
                // Stop at the first sentence that cannot leave on its own. Emitting the ones
                // after it moved the anchor past it, and it was never emitted at all: "Yes. I
                // agree with that." lost the "Yes." (research 2026-09-15, P5). Whatever is held
                // back here leaves together with what follows, through the tail path below.
                let emitted = emitIfViable(completed, continuation: continuation, tag: "sentence",
                                           confidence: currentSegmentConfidence,
                                           forceEmit: Self.isStandaloneUtterance(completed))
                guard emitted else { break }
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
}
