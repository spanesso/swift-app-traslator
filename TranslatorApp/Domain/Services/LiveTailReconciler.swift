//
//  LiveTailReconciler.swift
//  TranslatorApp
//
//  Turns the recogniser's cumulative text into the still-uncommitted live tail
//  (008-fix-audio-pipeline-resilience US2; bounded rewrite in 010 for main-thread cost).
//
//  WHAT THIS FIXES (symptom S3)
//  The logic used to sit inline in the ViewModel and compared incoming text against the joined
//  text of EVERY phrase committed so far. After the first rotation the live pane went blank and
//  stayed blank, because a ~60 s recognition session can never out-count the whole meeting.
//
//  WHY IT IS BOUNDED
//  This runs on the MAIN ACTOR, once per ASR partial — roughly three times a second, for the
//  whole meeting. The first version copied and split the recogniser's entire cumulative text on
//  every call. Once on-device recognition removed the ~1-minute session limit that text stopped
//  resetting, so the per-partial cost grew with meeting length: unnoticeable at five minutes,
//  a visible stutter at sixty.
//
//  Everything here is now O(window), never O(meeting). The live tail is short by definition —
//  it is the part not yet committed — so nothing is lost by refusing to look further back.
//

import Foundation

struct LiveTailReconciler: Sendable {

    /// How far back to look in the incoming text. Generous next to a real live tail (a handful
    /// of words, capped by the segmenter's 3 s emission ceiling) and still a hard bound.
    private static var scanWindowWords: Int { 120 }
    /// How much committed text to keep for matching. Only the end is ever needed.
    private static var committedTailWords: Int { 40 }
    /// Longest anchor tried when locating the committed text inside the incoming window.
    private static var maxAnchorWords: Int { 12 }

    /// Words committed since the CURRENT recognition session began — the count is the authority
    /// for position; the text is only kept as a bounded tail for matching.
    private(set) var committedWordCountInSession: Int = 0
    private var committedTail: [String] = []

    nonisolated init() {}

    /// Records a phrase committed while the current recognition session is still alive.
    ///
    /// Appends into a bounded ring rather than growing one string. The previous version built
    /// `committed + " " + phrase` on every commit, which copies the whole meeting each time and
    /// costs O(L²) over a session.
    mutating func commit(_ phrase: String) {
        let words = phrase.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return }
        committedWordCountInSession += words.count
        committedTail.append(contentsOf: words)
        if committedTail.count > Self.committedTailWords {
            committedTail.removeFirst(committedTail.count - Self.committedTailWords)
        }
    }

    /// The recogniser rotated. Everything committed before is no longer comparable against what
    /// the new session will produce, so the baseline resets. The caller's visible history is
    /// deliberately NOT touched (FR-012).
    mutating func recognitionSessionDidRestart() {
        committedWordCountInSession = 0
        committedTail.removeAll(keepingCapacity: true)
    }

    /// Clears everything, for a brand-new recording session.
    mutating func reset() {
        recognitionSessionDidRestart()
    }

    /// Computes the live tail from the recogniser's cumulative text.
    ///
    /// Locates the end of the committed text inside a bounded window at the end of the incoming
    /// text and returns whatever follows it. Matching ignores case, accents and punctuation
    /// because those are exactly what `addsPunctuation` keeps rewriting.
    mutating func liveTail(from recognizerFullText: String) -> ReconcileResult {
        let window = Self.trailingWords(of: recognizerFullText, limit: Self.scanWindowWords)
        guard !window.isEmpty else {
            return ReconcileResult(tail: "", branch: .noCommitted, detectedRestart: false)
        }

        guard committedWordCountInSession > 0, !committedTail.isEmpty else {
            return ReconcileResult(tail: window.joined(separator: " "),
                                   branch: .noCommitted,
                                   detectedRestart: false)
        }

        if let tail = Self.tailAfterAnchor(window: window, committedTail: committedTail) {
            return ReconcileResult(tail: tail, branch: .hasPrefix, detectedRestart: false)
        }

        // Nothing of what we already showed appears in the incoming text. Either the recogniser
        // restarted, or it rewrote so heavily that the anchor is gone.
        if window.count * 2 < committedWordCountInSession {
            recognitionSessionDidRestart()
            return ReconcileResult(tail: window.joined(separator: " "),
                                   branch: .restartDetected,
                                   detectedRestart: true)
        }
        // A heavy rewrite of text we already committed: nothing new to show yet. Returning the
        // window here would replay phrases the reader has already read.
        return ReconcileResult(tail: "", branch: .wordCount, detectedRestart: false)
    }

    // MARK: - Bounded helpers

    /// The last `limit` words, found by scanning backwards. Never touches the front of the
    /// string, so the cost is the size of the window, not the size of the meeting.
    static func trailingWords(of text: String, limit: Int) -> [String] {
        var words: [String] = []
        words.reserveCapacity(limit)
        var end = text.endIndex

        while end > text.startIndex, words.count < limit {
            // Skip separators before the next word.
            var cursor = end
            while cursor > text.startIndex,
                  text[text.index(before: cursor)].isWhitespace {
                cursor = text.index(before: cursor)
            }
            guard cursor > text.startIndex else { break }
            let wordEnd = cursor
            while cursor > text.startIndex,
                  !text[text.index(before: cursor)].isWhitespace {
                cursor = text.index(before: cursor)
            }
            words.append(String(text[cursor..<wordEnd]))
            end = cursor
        }
        return words.reversed()
    }

    /// Finds the committed text inside the window and returns what follows it.
    ///
    /// Tries progressively shorter anchors: the recogniser routinely rewrites the last few words
    /// it emitted, so insisting on a long exact match would fail constantly.
    private static func tailAfterAnchor(window: [String], committedTail: [String]) -> String? {
        let normalizedWindow = window.map { normalize($0) }
        let normalizedCommitted = committedTail.map { normalize($0) }

        let longest = min(maxAnchorWords, normalizedCommitted.count, normalizedWindow.count)
        guard longest >= 1 else { return nil }

        for anchorLength in stride(from: longest, through: 1, by: -1) {
            let anchor = Array(normalizedCommitted.suffix(anchorLength))
            // Last occurrence: if the phrase repeats, the most recent one is the boundary.
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

    private static func normalize(_ word: String) -> String {
        word.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
                     locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined()
    }
}

nonisolated struct ReconcileResult: Sendable, Equatable {
    let tail: String
    let branch: PrefixBranch
    let detectedRestart: Bool

    nonisolated init(tail: String, branch: PrefixBranch, detectedRestart: Bool) {
        self.tail = tail
        self.branch = branch
        self.detectedRestart = detectedRestart
    }
}
