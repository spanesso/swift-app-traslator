//
//  NLPSegmenterService+Utterance.swift
//  TranslatorApp
//
//  Telling a revision of the committed utterance from a new one (field report 2026-09-15:
//  "when the other person starts talking, their first words are lost").
//  Split from NLPSegmenterService+Text.swift to keep both under the 250-line convention.
//
//  On a change of speaker the recogniser restarts its transcript without saying so. When the
//  previous utterance was long, the text collapses and `didRestartTranscript` sees it. When it was
//  short, nothing collapses, and two things used to happen to the new speaker's first words:
//  a one-word anchor ("there") matched inside the new sentence and everything before it was taken
//  as already committed; or no anchor matched and the new text was read by POSITION in the old
//  utterance, skipping as many words as the previous speaker had said.
//
//  The test for both is the same: look at the words just before the committed boundary. A
//  revision keeps most of them; a new utterance shares almost none. Counted as shared words, not
//  by position — the recogniser inserts and splits words while revising, and a position-based
//  comparison mistook those revisions for new speakers and emitted them twice (next field log).
//

import Foundation

extension NLPSegmenterService {

    /// A short anchor is believed only when the words before it match what was committed too.
    nonisolated static func anchorContinuesCommitted(window: [String], tailStart: Int, committedTail: [String]) -> Bool {
        TranscriptWindow.isSameUtterance(
            TranscriptWindow.boundaryOverlap(window: window, windowEnd: tailStart,
                                             committedTail: committedTail, committedEnd: committedTail.count))
    }

    /// Whether the recogniser's text is still the utterance the committed words came from,
    /// compared word for word at the same positions just before the committed boundary.
    nonisolated static func continuesCommittedUtterance(window: [String],
                                                        totalWords: Int,
                                                        committedWordCount: Int,
                                                        committedTail: [String]) -> Bool {
        let windowStart = totalWords - window.count
        // `committedTail` can reach back into earlier utterances; its last word is at
        // utterance position `committedWordCount - 1`.
        let tailStartPosition = committedWordCount - committedTail.count
        let boundary = min(totalWords, committedWordCount)
        return TranscriptWindow.isSameUtterance(
            TranscriptWindow.boundaryOverlap(window: window,
                                             windowEnd: boundary - windowStart,
                                             committedTail: committedTail,
                                             committedEnd: boundary - tailStartPosition))
    }

    /// The recogniser restarted its transcript for a new utterance without a collapse in length —
    /// the previous utterance was short, so `didRestartTranscript` cannot see it.
    func startsNewUtterance(_ fullText: String) -> Bool {
        guard committedWordCount > 0, !committedTailWords.isEmpty, fullText != lastSeenFullText else {
            return false
        }
        let window = TranscriptWindow.trailingWords(of: fullText, limit: Self.pendingScanWindow)
        let committedTail = committedTailWords
        let anchored = TranscriptWindow.tailAfterAnchor(
            window: window,
            committedTail: committedTail,
            shortAnchorIsTrusted: { Self.anchorContinuesCommitted(window: window, tailStart: $0, committedTail: committedTail) }
        ) != nil
        guard !anchored else { return false }
        return !Self.continuesCommittedUtterance(window: window,
                                                 totalWords: wordCountOf(fullText),
                                                 committedWordCount: committedWordCount,
                                                 committedTail: committedTail)
    }
}
