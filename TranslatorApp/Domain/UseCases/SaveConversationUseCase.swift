//
//  SaveConversationUseCase.swift
//  TranslatorApp
//

import Foundation
import OSLog

enum ConversationError: Error, LocalizedError {
    case emptyTranscript

    var errorDescription: String? {
        "Nothing to save — no speech was captured."
    }
}

final class SaveConversationUseCase {
    private let repository: ConversationRepositoryProtocol
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UseCase")

    init(repository: ConversationRepositoryProtocol) {
        self.repository = repository
    }

    func execute(englishText: String, spanishText: String) async throws {
        let trimmedEN = englishText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEN.isEmpty else {
            throw ConversationError.emptyTranscript
        }
        let entity = ConversationEntity(
            id: UUID(),
            englishText: trimmedEN,
            spanishText: spanishText.trimmingCharacters(in: .whitespacesAndNewlines),
            savedAt: Date()
        )
        logger.info("📝 [UseCase] Saving conversation (\(trimmedEN.count) EN chars, \(spanishText.count) ES chars)")
        try await repository.save(entity)
        logger.info("✅ [UseCase] Conversation saved successfully id=\(entity.id)")
    }
}
