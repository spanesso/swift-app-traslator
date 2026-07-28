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
        advanceConsumed(consumedWords)
    }

    private func advanceConsumed(_ words: Int) {
        committedWordCount += words
        pendingStartedAt = nil
        cancelTimers()
    }

    // MARK: - Text helpers

    /// The still-uncommitted suffix of the recogniser's cumulative text.
    ///
    /// `SFSpeechRecognizer` with `addsPunctuation` REWRITES the whole string as it goes —
    /// capitalisation, commas, and corrected words — so the exact-prefix test fails routinely
    /// and the word count can even go DOWN between two partials of the same utterance.
    ///
    /// The old code read a shrinking word count as "the recogniser restarted", wiped the
    /// committed baseline, and made the entire cumulative transcript pending again. Everything
    /// already emitted was then re-emitted and re-translated: that is the Spanish pane rewriting
    /// itself. A restart is now signalled explicitly by `SpeechSegment.sessionGeneration`, so
    /// that guess is unnecessary — and what remains of it is deliberately conservative.
    func pendingSuffix(of fullText: String) -> String {
        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = committedFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return normalized }
        if normalized.hasPrefix(committed) {
            return String(normalized.dropFirst(committed.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = normalized.split(whereSeparator: \.isWhitespace)
        // A real restart begins near zero. A revision moves the count by a word or two, so only
        // a collapse to under half the committed length is treated as a restart.
        if words.count * 2 < committedWordCount {
            committedFullText = ""; committedWordCount = 0; pendingStartedAt = nil
            return normalized
        }
        guard words.count > committedWordCount else { return "" }
        return words.dropFirst(committedWordCount).joined(separator: " ")
    }

    // MARK: - Overlap trimming

    /// Removes any leading run of words the candidate shares with the end of what is already
    /// committed.
    ///
    /// Even with a correct baseline, a revision can hand back a tail that starts inside text
    /// already on screen. Without this, the user reads a phrase, then reads a longer version of
    /// the same phrase a moment later and loses the thread. Comparison is case-, accent- and
    /// punctuation-insensitive because those are exactly what the recogniser keeps rewriting.
    func trimmingOverlapWithCommitted(_ candidate: String) -> String {
        let candidateWords = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !candidateWords.isEmpty else { return candidate }

        let committedWords = committedFullText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !committedWords.isEmpty else { return candidate }

        // Bounded: comparing against the last 40 committed words is plenty for a spoken tail and
        // keeps this off the list of things that could ever be slow.
        let window = Array(committedWords.suffix(40)).map { Self.normalizeWord($0) }
        let candidateNormalized = candidateWords.map { Self.normalizeWord($0) }
        let maxOverlap = min(window.count, candidateNormalized.count)
        guard maxOverlap > 0 else { return candidate }

        for length in stride(from: maxOverlap, through: 1, by: -1) where
            Array(window.suffix(length)) == Array(candidateNormalized.prefix(length)) {
            return candidateWords.dropFirst(length).joined(separator: " ")
        }
        return candidate
    }

    private nonisolated static func normalizeWord(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }

    func wordCountOf(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    func endsWithTerminator(_ text: String) -> Bool { ".!?".contains(text.last ?? " ") }

    func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            return true
        }
        return result
    }

    func cutAtLastClauseMarker(_ text: String) -> (head: String, tail: String)? {
        var bestCut: String.Index?
        for p in [",", ";", ":", "—"] {
            if let r = text.range(of: p, options: .backwards) {
                if bestCut == nil || r.upperBound > bestCut! { bestCut = r.upperBound }
            }
        }
        for conn in [" and ", " but ", " so ", " because ", " however ", " yet ", " although "] {
            if let r = text.range(of: conn, options: .backwards) {
                if bestCut == nil || r.lowerBound > bestCut! { bestCut = r.lowerBound }
            }
        }
        guard let cut = bestCut else { return nil }
        return (String(text[..<cut]), String(text[cut...]))
    }

    /// Whether the phrase is grammatically open and probably unfinished.
    ///
    /// 008 (FR-014 context): the old version also returned true for ANY tail of more than two
    /// words in which NLTagger found no verb. In partial transcription the tail is usually a
    /// noun fragment, so that condition fired almost always and pinned emission to the slow
    /// 2.5 s path. Narrowed to the signal that actually means "unfinished": a dangling
    /// function word at the end.
    func isLikelyIncomplete(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var lastTag: NLTag?
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag { lastTag = tag }
            return true
        }
        let dangling: Set<NLTag> = [.preposition, .conjunction, .determiner, .particle]
        if let last = lastTag, dangling.contains(last) { return true }
        return false
    }
}
