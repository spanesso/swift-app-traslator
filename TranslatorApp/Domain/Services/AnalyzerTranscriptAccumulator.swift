//
//  AnalyzerTranscriptAccumulator.swift
//  TranslatorApp
//
//  Turns SpeechTranscriber's results into the cumulative text the pipeline reads
//  (SpeechAnalyzer migration, 2026-09-15).
//
//  SpeechTranscriber reports two kinds of result: VOLATILE ones — its current best guess for the
//  audio not yet finalised, replaced by the next one — and FINAL ones, which never change again.
//  The segmenter and the live pane expect one growing string, like SFSpeechRecognizer's, so the
//  finals are appended and the latest volatile is shown after them.
//
//  Unlike SFSpeechRecognizer, this string does not reset itself at a change of speaker — the
//  cause of every "first words lost" defect so far. It only starts over deliberately, after a
//  final, once it has grown past `rolloverWords`, and it says so with a new generation, which the
//  segmenter already treats as a clean boundary.
//

import Foundation

nonisolated struct AnalyzerTranscriptAccumulator: Sendable {

    nonisolated struct Update: Sendable, Equatable {
        /// Finalised text followed by the current volatile guess: what is being said right now.
        let text: String
        /// Finalised text only. It never changes once written, so it is what phrases are built
        /// from — building them from volatile text committed words the recogniser then rewrote.
        let finalizedText: String
        let generation: Int
        /// True when this update added finalised text.
        let didFinalize: Bool

        nonisolated init(text: String, finalizedText: String, generation: Int, didFinalize: Bool) {
            self.text = text
            self.finalizedText = finalizedText
            self.generation = generation
            self.didFinalize = didFinalize
        }
    }

    private let rolloverWords: Int
    private var finalized = ""
    private var finalizedWords = 0
    private var volatile = ""
    private var generation = 0
    private var rolloverPending = false

    /// Whether a volatile guess is waiting to be finalised.
    nonisolated var hasPendingGuess: Bool { !volatile.isEmpty }

    nonisolated init(rolloverWords: Int = 300) {
        self.rolloverWords = rolloverWords
    }

    nonisolated mutating func apply(text: String, isFinal: Bool) -> Update {
        if rolloverPending {
            rolloverPending = false
            generation += 1
            finalized = ""
            finalizedWords = 0
        }

        let piece = Self.fromFirstWord(text)
        if isFinal, piece.isEmpty {
            // A final with no words — "......", "." — returned when finalisation is requested
            // where nobody finished a word. It is not text: glued to the next phrase it showed as
            // "...... She remembered…", and alone as a line "too short to translate"
            // (field screenshot 2026-09-15).
            volatile = ""
            return Update(text: finalized, finalizedText: finalized, generation: generation, didFinalize: false)
        }
        if isFinal {
            finalized = Self.join(finalized, piece)
            finalizedWords += piece.split(whereSeparator: \.isWhitespace).count
            volatile = ""
            // Only after a final, so nothing still being revised is cut in two.
            if finalizedWords >= rolloverWords { rolloverPending = true }
        } else {
            volatile = piece
        }
        return Update(text: Self.join(finalized, volatile),
                      finalizedText: finalized,
                      generation: generation,
                      didFinalize: isFinal && !piece.isEmpty)
    }

    /// The text from its first letter or digit on. Punctuation before the first word (". That's my
    /// son's name.") closes a sentence that already ended; nothing but punctuation is no text.
    private nonisolated static func fromFirstWord(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstWord = trimmed.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return String(trimmed[firstWord...])
    }

    private nonisolated static func join(_ head: String, _ tail: String) -> String {
        if head.isEmpty { return tail }
        if tail.isEmpty { return head }
        return head + " " + tail
    }
}
