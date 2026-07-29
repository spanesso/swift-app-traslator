//
//  NLPSegmenterService+Timing.swift
//  TranslatorApp
//
//  Emission timing, the pending-tail ceiling, and text helpers
//  (008-fix-audio-pipeline-resilience, US3).
//  Split from NLPSegmenterService.swift to keep both files under the 250-line convention.
//

import Foundation
import NaturalLanguage

extension NLPSegmenterService {

    // MARK: - Stability timer

    /// Arms the silence timer for `tail`. When it fires and the tail is unchanged, the phrase
    /// is emitted — this is what turns a speaker's pause into a translation.
    func arm(tail: String,
             confidence: Float,
             reason: StabilityCancelReason,
             continuation: AsyncStream<SegmentedPhrase>.Continuation) {
        stabilityTimer?.cancel()

        let isLowQuality = lastKnownLowQuality
        let isIncomplete = isLikelyIncomplete(tail)
        let delayNs: UInt64
        let delayReason: StabilityDelayReason
        if isIncomplete {
            delayNs = stabilityDelayIncompleteNs; delayReason = .incomplete
        } else if isLowQuality {
            delayNs = stabilityDelayLowQualityNs; delayReason = .lowQuality
        } else {
            delayNs = stabilityDelayNs; delayReason = .normal
        }

        telemetry.stabilityArmed(sessionId,
                                 delayMs: Int(delayNs / 1_000_000),
                                 reason: delayReason,
                                 tailWords: wordCountOf(tail))

        let armedAt = MonotonicClock.now()
        stabilityTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delayNs)
            guard !Task.isCancelled, let self else { return }
            await self.stabilityDidFire(expecting: tail,
                                        confidence: confidence,
                                        armedAt: armedAt,
                                        continuation: continuation)
        }
    }

    /// Re-arms the timer after a path that previously returned without doing so.
    ///
    /// Every early return in `ingest` funnels through here. The `rescheduled=true` field in the
    /// STAB_CANCEL event is what makes the fix observable in the field: a line with
    /// `rescheduled=false` and a non-empty tail would mean the defect is back.
    func reschedule(reason: StabilityCancelReason,
                    continuation: AsyncStream<SegmentedPhrase>.Continuation) {
        let tail = pendingSuffix(of: lastSeenFullText).trimmingCharacters(in: .whitespacesAndNewlines)
        let ageMs = pendingStartedAt.map { MonotonicClock.msSince($0) } ?? 0

        guard !tail.isEmpty else {
            telemetry.stabilityCancelled(sessionId, reason: reason, rescheduled: false,
                                         pendingTailWords: 0, pendingAgeMs: ageMs)
            stabilityTimer?.cancel()
            stabilityTimer = nil
            return
        }

        telemetry.stabilityCancelled(sessionId, reason: reason, rescheduled: true,
                                     pendingTailWords: wordCountOf(tail), pendingAgeMs: ageMs)
        arm(tail: tail, confidence: currentSegmentConfidence, reason: reason, continuation: continuation)
    }

    private func stabilityDidFire(expecting tail: String,
                                  confidence: Float,
                                  armedAt: ContinuousClock.Instant,
                                  continuation: AsyncStream<SegmentedPhrase>.Continuation) {
        let currentTail = pendingSuffix(of: lastSeenFullText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let matches = currentTail == tail
        telemetry.stabilityFired(sessionId,
                                 armedToFiredMs: MonotonicClock.msSince(armedAt),
                                 tailWords: wordCountOf(tail),
                                 emitted: matches)
        guard matches else { return }
        emitIfViable(tail, continuation: continuation, tag: "stability", confidence: confidence)
    }

    // MARK: - Pending ceiling (FR-014)

    /// Independent watchdog over the age of the pending tail.
    ///
    /// The old ceiling was only evaluated when a NEW segment arrived carrying a non-empty
    /// pending suffix. During a pause that condition never held, so the supposed safety net
    /// never fired. A timer owes nothing to the input stream.
    func armCeiling(continuation: AsyncStream<SegmentedPhrase>.Continuation) {
        ceilingTimer?.cancel()
        let ceilingMs = maxPendingIntervalMs
        ceilingTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ceilingMs) * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.ceilingDidFire(continuation: continuation)
        }
    }

    private func ceilingDidFire(continuation: AsyncStream<SegmentedPhrase>.Continuation) {
        let tail = pendingSuffix(of: lastSeenFullText).trimmingCharacters(in: .whitespacesAndNewlines)
        let ageMs = pendingStartedAt.map { MonotonicClock.msSince($0) } ?? 0
        telemetry.pendingAge(sessionId,
                             pendingAgeMs: ageMs,
                             pendingWords: wordCountOf(tail),
                             ceilingMs: maxPendingIntervalMs)
        guard !tail.isEmpty else { return }
        stabilityTimer?.cancel()
        emitIfViable(tail, continuation: continuation, tag: "ceiling",
                     confidence: currentSegmentConfidence, forceEmit: true)
    }

    func cancelTimers() {
        stabilityTimer?.cancel(); stabilityTimer = nil
        ceilingTimer?.cancel(); ceilingTimer = nil
    }

    // MARK: - Emission

    /// Consumed position and emitted text are tracked separately.
    ///
    /// `committedWordCount` is an index into the recogniser's cumulative word stream;
    /// `committedFullText` is what the user actually saw. Overlap trimming makes the second
    /// shorter than the first, and conflating them would re-offer the trimmed words on the next
    /// partial — the same duplicate, forever.
    func emitIfViable(_ rawText: String,
                      continuation: AsyncStream<SegmentedPhrase>.Continuation,
                      tag: String,
                      confidence: Float,
                      forceEmit: Bool = false) {
        let candidate = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else { return }
        let consumedWords = wordCountOf(candidate)

        // Clause cuts can leave a phrase starting on the separator itself (", but it's really…").
        let separators = CharacterSet(charactersIn: ",;:—- ").union(.whitespacesAndNewlines)
        let display = trimmingOverlapWithCommitted(candidate)
            .trimmingCharacters(in: separators)

        guard !display.isEmpty else {
            // Everything in this candidate was already on screen. The words were still consumed,
            // so advance past them instead of offering the same overlap again.
            advanceConsumed(consumedWords)
            return
        }
        guard forceEmit || wordCountOf(display) >= minShortPhraseWords else { return }

        commit(display, consumedWords: consumedWords)
        continuation.yield(SegmentedPhrase(text: display, confidence: confidence))
    }

    private func commit(_ text: String, consumedWords: Int) {
        committedFullText = committedFullText.isEmpty ? text : committedFullText + " " + text
        // Bounded tail for overlap trimming, so that path never touches the full transcript.
        committedTailWords.append(contentsOf: text.split(whereSeparator: \.isWhitespace).map(String.init))
        if committedTailWords.count > Self.committedTailLimit {
            committedTailWords.removeFirst(committedTailWords.count - Self.committedTailLimit)
        }
        advanceConsumed(consumedWords)
    }

    private func advanceConsumed(_ words: Int) {
        committedWordCount += words
        pendingStartedAt = nil
        cancelTimers()
    }
}
