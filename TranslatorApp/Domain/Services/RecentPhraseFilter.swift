//
//  RecentPhraseFilter.swift
//  TranslatorApp
//
//  Tells the pipeline repeating itself apart from a person saying something again
//  (research 2026-09-15, finding P2).
//
//  The ViewModel used to remember every phrase of the meeting and drop any later phrase with the
//  same normalised text. Meetings are full of legitimate repeats — "Okay.", "Thank you.", "Yes,
//  exactly." — and every second one was discarded before it was journaled, so it was neither on
//  screen, nor translated, nor recoverable.
//
//  A duplicate the pipeline produces arrives immediately after the original: a replayed carry-over
//  window, or a final result restating a partial that was already committed. So only a phrase
//  that matches one of the last few, within a short window, is treated as one — and never a
//  short reply, which is precisely what people repeat.
//

import Foundation

nonisolated struct RecentPhraseFilter: Sendable {

    /// Below this, a repeat is someone answering again, not the pipeline echoing.
    nonisolated static var minimumWords: Int { 3 }
    /// How recent the original must be. Pipeline echoes arrive within a rotation's reach.
    nonisolated static var windowMs: Int { 15_000 }
    /// How many of the latest phrases are compared against.
    nonisolated static var recentCount: Int { 3 }

    private struct Entry: Sendable {
        let key: String
        let at: ContinuousClock.Instant
    }

    private var recent: [Entry] = []

    nonisolated init() {}

    /// Whether `key` (already normalised) repeats a phrase that was just committed. A phrase that
    /// is not a duplicate is remembered.
    nonisolated mutating func isDuplicate(_ key: String, at now: ContinuousClock.Instant) -> Bool {
        let words = key.split(separator: " ").count
        let duplicate = words >= Self.minimumWords && recent.contains { entry in
            entry.key == key && MonotonicClock.milliseconds(from: entry.at, to: now) <= Self.windowMs
        }
        guard !duplicate else { return true }
        recent.append(Entry(key: key, at: now))
        if recent.count > Self.recentCount { recent.removeFirst() }
        return false
    }

    nonisolated mutating func reset() {
        recent.removeAll()
    }
}
