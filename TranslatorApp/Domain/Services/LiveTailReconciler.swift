//
//  LiveTailReconciler.swift
//  TranslatorApp
//
//  Turns the recogniser's cumulative text into the still-uncommitted live tail
//  (008-fix-audio-pipeline-resilience, US2).
//
//  THE BUG THIS REPLACES (symptom S3)
//  The logic used to sit inline in the ViewModel and compared incoming text against the joined
//  text of EVERY phrase committed so far in the meeting — a value that only ever grew and was
//  never cleared within a session.
//
//  After the first rotation (~1 minute in) the new recognition session starts its transcript
//  from zero:
//    · `full.hasPrefix(committed)` fails, because the new text does not continue the old
//    · the word-count fallback compares 4 incoming words against ~300 committed ones
//    · 4 > 300 is false, so the live tail became ""
//
//  And it stayed "" forever: a recognition session capped at ~60 seconds can never out-count
//  the whole meeting. The pane froze on whatever was last rendered.
//
//  The fix is not a better fallback. It is comparing against the right baseline: what has been
//  committed SINCE THE CURRENT recognition session began. `recognitionSessionDidRestart()`
//  resets that baseline; the visible history is untouched.
//
//  Pure and deterministic — no dates, no I/O, no global state — so it is unit-testable without
//  audio hardware, which the inline version was not.
//

import Foundation

struct LiveTailReconciler: Sendable {

    /// Text committed since the CURRENT recognition session started. Not the meeting's history.
    private(set) var committedInSession: String = ""
    private(set) var committedWordCountInSession: Int = 0

    nonisolated init() {}

    /// Records a phrase committed while the current recognition session is still alive.
    mutating func commit(_ phrase: String) {
        let trimmed = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        committedInSession = committedInSession.isEmpty
            ? trimmed
            : committedInSession + " " + trimmed
        committedWordCountInSession += Self.wordCount(trimmed)
    }

    /// The recogniser rotated. Everything committed before is no longer comparable against what
    /// the new session will produce, so the baseline resets. The caller's visible history is
    /// deliberately NOT touched (FR-012).
    mutating func recognitionSessionDidRestart() {
        committedInSession = ""
        committedWordCountInSession = 0
    }

    /// Clears everything, for a brand-new recording session.
    mutating func reset() {
        recognitionSessionDidRestart()
    }

    /// Computes the live tail from the recogniser's cumulative text.
    ///
    /// Contract:
    ///  · prefix matches                  → the suffix
    ///  · incoming word count ≤ committed → treated as a restart: baseline resets and the WHOLE
    ///                                      text is returned. This path never yields "" — that
    ///                                      was precisely the defect
    ///  · nothing committed in session    → the whole text
    mutating func liveTail(from recognizerFullText: String) -> ReconcileResult {
        let full = recognizerFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = committedInSession.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !committed.isEmpty else {
            return ReconcileResult(tail: full, branch: .noCommitted, detectedRestart: false)
        }

        if full.hasPrefix(committed) {
            let tail = String(full.dropFirst(committed.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return ReconcileResult(tail: tail, branch: .hasPrefix, detectedRestart: false)
        }

        let words = full.split(whereSeparator: \.isWhitespace)
        // A restart begins near zero; a revision moves the count by a word or two. Requiring a
        // collapse to under half keeps a rewritten partial — which `addsPunctuation` produces
        // constantly, sometimes shortening the text — from being mistaken for a restart and
        // dumping the whole transcript back into the live tail.
        if words.count * 2 < committedWordCountInSession {
            recognitionSessionDidRestart()
            return ReconcileResult(tail: full, branch: .restartDetected, detectedRestart: true)
        }

        guard words.count > committedWordCountInSession else {
            return ReconcileResult(tail: "", branch: .wordCount, detectedRestart: false)
        }
        let tail = words.dropFirst(committedWordCountInSession).joined(separator: " ")
        return ReconcileResult(tail: tail, branch: .wordCount, detectedRestart: false)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: \.isWhitespace).count
    }
}

struct ReconcileResult: Sendable, Equatable {
    let tail: String
    let branch: PrefixBranch
    let detectedRestart: Bool

    nonisolated init(tail: String, branch: PrefixBranch, detectedRestart: Bool) {
        self.tail = tail
        self.branch = branch
        self.detectedRestart = detectedRestart
    }
}
