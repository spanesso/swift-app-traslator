//
//  FinalizationPacer.swift
//  TranslatorApp
//
//  Decides when to ask SpeechAnalyzer to finalise what it has heard (field log 2026-09-15).
//
//  Phrases are built only from finalised text, and left to itself SpeechTranscriber finalised late
//  and in large pieces: the first phrase 13 s into the meeting, then stretches of 15–25 s with
//  nothing, ending in blocks of 251 characters. The speaker's own pauses are the natural place to
//  finalise, so a short quiet stretch while a guess is pending asks for it — and so does a guess
//  that has been pending for a long time, for someone who talks without pausing.
//
//  QUIET RELATIVE TO THE ROOM (second field log). With a fixed -45 dBFS floor, 6 of 7
//  finalisations were forced mid-sentence every 6 s: that room's background never went below the
//  floor, so no pause was ever seen, and each forced cut left punctuation-only fragments ("......").
//  A pause is now a level close to the lowest the room has been recently AND clearly below the
//  recent speech; the forced cut is a last resort at 15 s.
//
//  Pure, so the timing is testable without a microphone.
//

import Foundation

nonisolated struct FinalizationPacer: Sendable {

    nonisolated enum Reason: String, Sendable, Equatable {
        case pause
        case longUtterance
    }

    /// Always quiet at or below this: the meter's speech floor (-45 dBFS on its 0…1 scale).
    nonisolated static var quietLevel: Float { 0.25 }
    /// How far above the room's background still counts as the room's background.
    nonisolated static var marginAboveBackground: Float { 0.12 }
    /// How far below the recent speech a level must be to count as a pause.
    nonisolated static var dropBelowSpeech: Float { 0.15 }
    /// A pause between phrases, not the gap between two words.
    nonisolated static var pauseMs: Int { 500 }
    /// Last resort for someone who never pauses.
    nonisolated static var maxPendingMs: Int { 15_000 }
    /// How much recent level history defines "the room" and "the speech".
    nonisolated static var historyTicks: Int { 80 }

    private var quietMs = 0
    private var pendingMs = 0
    private var history: [Float] = []

    nonisolated init() {}

    /// Feed one tick. Returns why finalisation should be requested now, or nil.
    nonisolated mutating func tick(elapsedMs: Int, hasPendingGuess: Bool, level: Float) -> Reason? {
        remember(level)
        guard hasPendingGuess else {
            quietMs = 0
            pendingMs = 0
            return nil
        }
        pendingMs += elapsedMs
        quietMs = isQuiet(level) ? quietMs + elapsedMs : 0

        if quietMs >= Self.pauseMs {
            quietMs = 0
            pendingMs = 0
            return .pause
        }
        if pendingMs >= Self.maxPendingMs {
            quietMs = 0
            pendingMs = 0
            return .longUtterance
        }
        return nil
    }

    /// Finalised text arrived: whatever is pending now is new.
    nonisolated mutating func finalReceived() {
        pendingMs = 0
    }

    private nonisolated mutating func remember(_ level: Float) {
        history.append(level)
        if history.count > Self.historyTicks { history.removeFirst(history.count - Self.historyTicks) }
    }

    private nonisolated func isQuiet(_ level: Float) -> Bool {
        if level <= Self.quietLevel { return true }
        guard let background = history.min(), let speech = history.max() else { return false }
        return level <= background + Self.marginAboveBackground
            && level <= speech - Self.dropBelowSpeech
    }
}
