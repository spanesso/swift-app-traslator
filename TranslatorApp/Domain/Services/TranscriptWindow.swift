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
    nonisolated static func tailAfterAnchor(window: [String],
                                            committedTail: [String],
                                            maxAnchorWords: Int = 12) -> String? {
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
                    guard tailStart < window.count else { return "" }
                    return window[tailStart...].joined(separator: " ")
                }
                start -= 1
            }
        }
        return nil
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
