//
//  TranscriptWindow.swift
//  TranslatorApp
//
//  Bounded reading of the recogniser's cumulative text.
//
//  The recogniser hands back the WHOLE transcript on every update — three times a second, for
//  the entire meeting. Any component that reads it by copying or splitting the whole thing pays
//  a cost that grows with the meeting: unnoticeable at five minutes, a stutter at sixty.
//
//  Both readers of that text — the live-tail reconciler and the segmenter — only ever care
//  about the end of it, so both work through this. Every operation here is O(window), never
//  O(meeting).
//

import Foundation

enum TranscriptWindow {

    /// The last `limit` words, found by scanning backwards. Never touches the front of the
    /// string, so the cost is the size of the window and not the size of the meeting.
    nonisolated static func trailingWords(of text: String, limit: Int) -> [String] {
        var words: [String] = []
        words.reserveCapacity(limit)
        var end = text.endIndex

        while end > text.startIndex, words.count < limit {
            var cursor = end
            while cursor > text.startIndex, text[text.index(before: cursor)].isWhitespace {
                cursor = text.index(before: cursor)
            }
            guard cursor > text.startIndex else { break }
            let wordEnd = cursor
            while cursor > text.startIndex, !text[text.index(before: cursor)].isWhitespace {
                cursor = text.index(before: cursor)
            }
            words.append(String(text[cursor..<wordEnd]))
            end = cursor
        }
        return words.reversed()
    }

    /// Finds the already-committed text inside `window` and returns whatever follows it, or nil
    /// if no part of it can be located.
    ///
    /// Tries progressively shorter anchors: the recogniser routinely rewrites the last few words
    /// it emitted — capitalisation, punctuation, a corrected word — so insisting on one long
    /// exact match would fail constantly. Matching ignores case, accents and punctuation for the
    /// same reason.
    ///
    /// - Parameter shortAnchorIsTrusted: asked before believing an anchor shorter than
    ///   `trustedAnchorWords`, with the index where the tail would start. One or two words —
    ///   "there", "so we" — turn up in unrelated sentences, and a match in the middle of a NEW
    ///   utterance used to be taken as the committed boundary, skipping everything before it.
    nonisolated static func tailAfterAnchor(window: [String],
                                            committedTail: [String],
                                            maxAnchorWords: Int = 12,
                                            shortAnchorIsTrusted: (Int) -> Bool = { _ in true }) -> String? {
        guard !window.isEmpty, !committedTail.isEmpty else { return nil }
        let normalizedWindow = window.map { normalize($0) }
        let normalizedCommitted = committedTail.map { normalize($0) }

        let longest = min(maxAnchorWords, normalizedCommitted.count, normalizedWindow.count)
        guard longest >= 1 else { return nil }

        for anchorLength in stride(from: longest, through: 1, by: -1) {
            let anchor = Array(normalizedCommitted.suffix(anchorLength))
            // Last occurrence: if a phrase repeats, the most recent one is the real boundary.
            var start = normalizedWindow.count - anchorLength
            while start >= 0 {
                if Array(normalizedWindow[start..<(start + anchorLength)]) == anchor {
                    let tailStart = start + anchorLength
                    if anchorLength < trustedAnchorWords, !shortAnchorIsTrusted(tailStart) {
                        start -= 1
                        continue
                    }
                    guard tailStart < window.count else { return "" }
                    return window[tailStart...].joined(separator: " ")
                }
                start -= 1
            }
        }
        return nil
    }

    /// Anchors at least this long are believed on their own.
    nonisolated static var trustedAnchorWords: Int { 3 }

    /// How many of the last `limit` words of `window` before `windowEnd` also appear among the last
    /// words of `committedTail` before `committedEnd`, counted as a multiset.
    ///
    /// Shared words, not words at the same position: the recogniser inserts and splits words while
    /// revising ("before we ship" → "before we go and ship", "gonna" → "going to"), which moves
    /// every later word by a position. Compared position by position, such a revision looked like
    /// a different sentence, and the whole utterance was emitted a second time (field log
    /// 2026-09-15).
    nonisolated static func boundaryOverlap(window: [String],
                                            windowEnd: Int,
                                            committedTail: [String],
                                            committedEnd: Int,
                                            limit: Int = 8) -> (compared: Int, shared: Int) {
        guard windowEnd >= 0, windowEnd <= window.count,
              committedEnd >= 0, committedEnd <= committedTail.count else { return (0, 0) }
        let compared = min(limit, windowEnd, committedEnd)
        guard compared > 0 else { return (0, 0) }

        var pool: [String: Int] = [:]
        for word in committedTail[(committedEnd - compared)..<committedEnd] {
            pool[normalize(word), default: 0] += 1
        }
        var shared = 0
        for word in window[(windowEnd - compared)..<windowEnd] {
            let key = normalize(word)
            if let available = pool[key], available > 0 {
                pool[key] = available - 1
                shared += 1
            }
        }
        return (compared, shared)
    }

    /// Whether an overlap shows the SAME utterance: a revision keeps most words, a new utterance
    /// shares a few function words at most. Too little to compare counts as a new utterance —
    /// showing a few words twice can be lived with; skipping the new speaker's first words cannot.
    nonisolated static func isSameUtterance(_ overlap: (compared: Int, shared: Int)) -> Bool {
        overlap.compared >= 3 && overlap.shared * 3 >= overlap.compared * 2
    }

    /// Appends words to a tail, keeping at most `limit` of them.
    nonisolated static func appendBounded(_ words: [String], to tail: inout [String], limit: Int) {
        tail.append(contentsOf: words)
        if tail.count > limit {
            tail.removeFirst(tail.count - limit)
        }
    }

    nonisolated static func normalize(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}
