//
//  ConversationRecord.swift
//  TranslatorApp
//

import SwiftData
import Foundation

@Model
final class ConversationRecord {
    @Attribute(.unique) var id: UUID
    var englishText: String
    var spanishText: String
    var savedAt: Date

    init(id: UUID, englishText: String, spanishText: String, savedAt: Date) {
        self.id = id
        self.englishText = englishText
        self.spanishText = spanishText
        self.savedAt = savedAt
    }

    func toEntity() -> ConversationEntity {
        ConversationEntity(
            id: id,
            englishText: englishText,
            spanishText: spanishText,
            savedAt: savedAt
        )
    }
}
