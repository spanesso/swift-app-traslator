//
//  ConversationSummary.swift
//  TranslatorApp
//
//  What the history can show about a saved conversation without opening it (2026-09-15).
//  Deliberately nothing of its content: no preview, no word count. Reading any of that would
//  require decrypting it, and only the user may do that.
//

import Foundation

nonisolated struct ConversationSummary: Sendable, Identifiable, Equatable {
    let id: UUID
    let savedAt: Date

    nonisolated init(id: UUID, savedAt: Date) {
        self.id = id
        self.savedAt = savedAt
    }
}
