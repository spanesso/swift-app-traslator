//
//  NLPSegmenterService+Text.swift
//  TranslatorApp
//
//  Text analysis helpers for the segmenter: pending-suffix arithmetic, overlap trimming,
//  sentence splitting and grammatical-completeness heuristics.
//  Split out to keep every segmenter file under the 250-line convention.
//

import Foundation
import NaturalLanguage

extension NLPSegmenterService {

    /// Whether the recogniser threw its transcript away and started a new one.
    ///
    /// Compared against the PREVIOUS TEXT rather than against the committed baseline: the
    /// previous text is always one update old, so the signal is unambiguous. A revision moves
    /// the word count by one or two; a restart drops it to a fraction.
    nonisolated static func didRestartTranscript(previous: String, incoming: String) -> Bool {
        let previousWords = previous.split(whereSeparator: \.isWhitespace).count
        guard previousWords >= 4 else { return false }
        let incomingWords = incoming.split(whereSeparator: \.isWhitespace).count
        return incomingWords * 2 <= previousWords
    }

    /// The still-uncommitted suffix of the recogniser's cumulative text.
    ///
    /// `SFSpeechRecognizer` with `addsPunctuation` REWRITES the whole string as it goes —
    /// capitalisation, commas, corrected words — so an exact-prefix test fails routinely and the
    /// word count can even go DOWN between two partials of the same utterance. Reading a
    /// shrinking count as "the recogniser restarted" wiped the baseline and made everything
    /// already emitted pending again: that was the Spanish pane rewriting itself.
    ///
    /// Bounded (010): this used to keep the entire meeting in one string and copy it on
    /// every partial. Only the end of it was ever needed, so only the end is kept.
    func pendingSuffix(of fullText: String) -> String {
        let window = TranscriptWindow.trailingWords(of: fullText, limit: Self.pendingScanWindow)
        guard committedWordCount > 0, !committedTailWords.isEmpty else {
            anchorMisses = 0
            return window.joined(separator: " ")
        }
        let committedTail = committedTailWords
        if let tail = TranscriptWindow.tailAfterAnchor(
            window: window,
            committedTail: committedTail,
            shortAnchorIsTrusted: { Self.anchorContinuesCommitted(window: window, tailStart: $0, committedTail: committedTail) }
        ) {
            anchorMisses = 0
            return tail
        }

        let totalWords = wordCountOf(fullText)
        guard Self.continuesCommittedUtterance(window: window,
                                               totalWords: totalWords,
                                               committedWordCount: committedWordCount,
                                               committedTail: committedTail) else {
            // A new utterance the recogniser started without saying so — the other speaker. The
            // positions of the previous utterance mean nothing here; counting them skipped the new
            // speaker's first words (field report 2026-09-15).
            committedWordCount = 0
            pendingStartedAt = nil
            anchorMisses = 0
            return window.joined(separator: " ")
        }

        // Same utterance, no anchor, at least as long as what was consumed: a revision of the
        // committed words themselves — typically the LAST one ("Tuesday" → "Thursday"), which
        // every anchor ends on. Position is still valid there, so resume from it instead of
        // re-emitting the whole utterance (research 2026-09-15, D1 and D2).
        if totalWords >= committedWordCount {
            anchorMisses = 0
            let consumedInWindow = max(0, committedWordCount - (totalWords - window.count))
            return window.dropFirst(consumedInWindow).joined(separator: " ")
        }

        anchorMisses += 1
        // A real restart begins near zero; a revision moves the count by a word or two.
        //
        // The miss count is what makes this safe. The ratio test alone could never become true
        // again once the window had grown past half the committed count, so a baseline that went
        // stale — which is what an unsignalled transcript restart does — stalled the segmenter
        // for the REST OF THE MEETING: `pendingSuffix` returned "" on every update, no phrase
        // was ever emitted again, and nothing anywhere reported a problem.
        if window.count * 2 < committedWordCount || anchorMisses >= Self.maxAnchorMisses {
            committedWordCount = 0
            // Kept, not cleared: it is the only defence against re-showing the words that span
            // the boundary. `emitIfViable` trims them off the next candidate.
            pendingStartedAt = nil
            anchorMisses = 0
            return window.joined(separator: " ")
        }
        // A heavy rewrite of text already emitted: nothing new to show yet.
        return ""
    }

    // MARK: - Overlap trimming

    /// Removes any leading run of words the candidate shares with the end of what is already
    /// committed.
    ///
    /// Even with a correct baseline, a revision can hand back a tail that starts inside text
    /// already on screen. Without this, the user reads a phrase, then reads a longer version of
    /// the same phrase a moment later and loses the thread.
    ///
    /// Bounded (010): `committedTailWords` already holds only the last few dozen words. This
    /// used to split the ENTIRE meeting transcript and allocate a String per word — thousands of
    /// allocations — only to keep the last forty of them, on every emitted phrase.
    func trimmingOverlapWithCommitted(_ candidate: String) -> String {
        let candidateWords = candidate.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !candidateWords.isEmpty, !committedTailWords.isEmpty else { return candidate }

        let window = committedTailWords.map { TranscriptWindow.normalize($0) }
        let candidateNormalized = candidateWords.map { TranscriptWindow.normalize($0) }
        let maxOverlap = min(window.count, candidateNormalized.count)
        // At least two words. A single shared word — "so", "okay", "yes" — is far more often the
        // next speaker's first word than a repeat, and trimming it lost that word.
        guard maxOverlap >= 2 else { return candidate }

        for length in stride(from: maxOverlap, through: 2, by: -1) where
            Array(window.suffix(length)) == Array(candidateNormalized.prefix(length)) {
            return candidateWords.dropFirst(length).joined(separator: " ")
        }
        return candidate
    }

    // MARK: - Text helpers

    func wordCountOf(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }

    func endsWithTerminator(_ text: String) -> Bool { ".!?".contains(text.last ?? " ") }

    /// Whether a full stop on a PARTIAL result should be believed as the end of an utterance.
    ///
    /// Two ways to earn it:
    ///  · enough words that a sentence boundary is plausible, or
    ///  · a genuine standalone reply — "Yes.", "Okay." — which feature 006 (SC-003) went out of
    ///    its way to stop dropping, and which must keep arriving instantly.
    ///
    /// Everything else waits. A period after "of" or "we need" is the recogniser punctuating
    /// mid-sentence, and honouring it is what shredded the conversation in the field.
    func terminatorCompletesUtterance(_ tail: String) -> Bool {
        guard endsWithTerminator(tail) else { return false }
        if wordCountOf(tail) >= minWordsForTerminatorEmit { return true }
        return Self.isStandaloneUtterance(tail)
    }

    /// Short replies that really do stand alone. Deliberately a small, closed list: a wide one
    /// would start letting the recogniser's spurious periods back through, which is the defect
    /// this guards against.
    nonisolated static func isStandaloneUtterance(_ text: String) -> Bool {
        let word = text
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard word.count == 1 else { return false }
        return standaloneUtterances.contains(word[0])
    }

    private nonisolated static var standaloneUtterances: Set<String> {
        // Extended 2026-09-16 (field export): "good" answered "how are you?" and, not being on
        // this list, was glued onto the next speaker's unrelated sentence instead of standing on
        // its own — the anchor to the prior commit was still trusted, so neither restart detector
        // caught the speaker change either. Added the other common one-word acknowledgements this
        // guard was already meant to cover.
        ["yes", "yeah", "yep", "no", "nope", "okay", "ok", "right", "sure",
         "exactly", "correct", "thanks", "hello", "hi", "bye", "sorry", "please",
         "good", "nice", "cool", "great", "fine", "true", "perfect", "understood",
         "agreed", "definitely", "absolutely"]
    }

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
