//
//  ConversationRepository.swift
//  TranslatorApp
//

import SwiftData
import Foundation
import OSLog

final class ConversationRepository: ConversationRepositoryProtocol {
    private let context: ModelContext
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Persistence")

    init(context: ModelContext) {
        self.context = context
    }

    func save(_ conversation: ConversationEntity) async throws {
        let record = ConversationRecord(
            id: conversation.id,
            englishText: conversation.englishText,
            spanishText: conversation.spanishText,
            savedAt: conversation.savedAt
        )
        context.insert(record)
        try context.save()
        logger.info("💾 [Persistence] Saved conversation id=\(conversation.id) len=\(conversation.englishText.count)")
    }

    func fetchAll() async throws -> [ConversationEntity] {
        var descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        let records = try context.fetch(descriptor)
        logger.info("📋 [Persistence] Fetched \(records.count) conversations")
        return records.map { $0.toEntity() }
    }
}
