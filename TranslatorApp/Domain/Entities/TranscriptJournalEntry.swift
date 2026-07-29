//
//  TranscriptJournalEntry.swift
//  TranslatorApp
//
//  One durable record of something that happened in the live meeting
//  (010-transcript-durability, US1).
//
//  DESIGN: each entry is written EXACTLY ONCE and is independent of every other. That is what
//  makes a half-written journal recoverable — a process killed mid-write can only damage the
//  last entry, and every entry before it is still whole.
//
//  It also means entries may be written out of order without harm: there is at most one
//  `source` and one `translation` per fragment id, so replay is deterministic regardless of
//  arrival order. Recovery sorts by fragment id, not by position in the file.
//

import Foundation

nonisolated struct TranscriptJournalEntry: Sendable, Codable, Equatable {

    nonisolated enum Kind: String, Sendable, Codable {
        /// A phrase the segmenter confirmed. Written the moment it is committed.
        case source
        /// The outcome of translating that phrase: either text, or an explicit unavailability.
        case translation
    }

    let kind: Kind
    let fragmentId: Int
    let sessionId: String
    /// Wall-clock milliseconds. Only for showing the user when the recovered meeting happened;
    /// never used for ordering, which is what `fragmentId` is for.
    let epochMs: Int

    // Populated for `.source`
    let sourceText: String?
    let confidence: Float?

    // Populated for `.translation` — exactly one of the two.
    let translatedText: String?
    let unavailableReason: String?

    nonisolated init(kind: Kind,
                     fragmentId: Int,
                     sessionId: String,
                     epochMs: Int,
                     sourceText: String? = nil,
                     confidence: Float? = nil,
                     translatedText: String? = nil,
                     unavailableReason: String? = nil) {
        self.kind = kind
        self.fragmentId = fragmentId
        self.sessionId = sessionId
        self.epochMs = epochMs
        self.sourceText = sourceText
        self.confidence = confidence
        self.translatedText = translatedText
        self.unavailableReason = unavailableReason
    }

    // MARK: - Factories

    nonisolated static func source(_ fragment: ConversationFragment,
                                   sessionId: String,
                                   epochMs: Int) -> TranscriptJournalEntry {
        TranscriptJournalEntry(kind: .source,
                               fragmentId: fragment.id,
                               sessionId: sessionId,
                               epochMs: epochMs,
                               sourceText: fragment.sourceText,
                               confidence: fragment.sourceConfidence)
    }

    nonisolated static func translation(fragmentId: Int,
                                        outcome: TranslationOutcome,
                                        sessionId: String,
                                        epochMs: Int) -> TranscriptJournalEntry? {
        switch outcome {
        case .pending:
            // Nothing durable to say yet. Recovery treats a fragment with no translation entry
            // as pending, which is exactly right.
            return nil
        case .translated(let text):
            return TranscriptJournalEntry(kind: .translation,
                                          fragmentId: fragmentId,
                                          sessionId: sessionId,
                                          epochMs: epochMs,
                                          translatedText: text)
        case .unavailable(let reason):
            return TranscriptJournalEntry(kind: .translation,
                                          fragmentId: fragmentId,
                                          sessionId: sessionId,
                                          epochMs: epochMs,
                                          unavailableReason: reason.rawValue)
        }
    }

    /// The outcome this entry describes, for replay. Unknown reasons degrade to `.failed`
    /// rather than being dropped: a journal written by an older build must still recover.
    nonisolated var replayedOutcome: TranslationOutcome? {
        guard kind == .translation else { return nil }
        if let translatedText { return .translated(translatedText) }
        guard let unavailableReason else { return nil }
        let reason = TranslationOutcome.Reason(rawValue: unavailableReason) ?? .failed
        return .unavailable(reason)
    }
}

/// A meeting reconstructed from the journal after the app went away.
nonisolated struct RecoveredSession: Sendable, Equatable {
    let sessionId: String
    let fragments: [ConversationFragment]
    let startedAtEpochMs: Int

    nonisolated init(sessionId: String, fragments: [ConversationFragment], startedAtEpochMs: Int) {
        self.sessionId = sessionId
        self.fragments = fragments
        self.startedAtEpochMs = startedAtEpochMs
    }

    nonisolated var isEmpty: Bool { fragments.isEmpty }

    nonisolated var startedAt: Date {
        Date(timeIntervalSince1970: Double(startedAtEpochMs) / 1000.0)
    }
}
