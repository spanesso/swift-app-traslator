//
//  ConversationEntity.swift
//  TranslatorApp
//

import Foundation

struct ConversationEntity: Sendable {
    let id: UUID
    let englishText: String
    let spanishText: String
    let savedAt: Date

    var preview: String {
        let trimmed = englishText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "(no transcript)" }
        if trimmed.count <= 100 { return trimmed }
        return String(trimmed.prefix(100)) + "…"
    }
}
