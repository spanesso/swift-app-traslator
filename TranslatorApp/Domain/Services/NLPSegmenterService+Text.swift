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
            committedTailWords.removeAll(keepingCapacity: true)
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

        // Bounded by construction: `committedTailWords` already holds only the last few dozen
        // words. The previous version split the ENTIRE meeting transcript and allocated a String
        // per word — thousands of allocations — only to keep the last 40 of them, on every
        // emitted phrase.
        guard !committedTailWords.isEmpty else { return candidate }
        let window = committedTailWords.map { Self.normalizeWord($0) }
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
        ["yes", "yeah", "yep", "no", "nope", "okay", "ok", "right", "sure",
         "exactly", "correct", "thanks", "hello", "hi", "bye", "sorry", "please"]
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
