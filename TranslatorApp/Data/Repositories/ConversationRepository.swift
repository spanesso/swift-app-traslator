//
//  ConversationRepository.swift
//  TranslatorApp
//
//  Saved conversations, sealed (2026-09-15).
//
//  A conversation is stored as ONE envelope — both languages together, encrypted to this device's
//  key — in the existing `englishText` field, with `spanishText` left empty. The schema does not
//  change, so no migration is needed (feature 008, decision Q2). Nothing of what was said is ever
//  written to the store in clear, and nothing is ever logged but sizes.
//
//  Honest limit: conversations saved in clear by earlier versions are re-written sealed, but SQLite
//  does not guarantee the old pages are overwritten immediately. They stay under iOS file
//  encryption until reused.
//

import SwiftData
import Foundation
import OSLog

final class ConversationRepository: ConversationRepositoryProtocol {
    private let context: ModelContext
    private let sealer: any ConversationSealingProtocol
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Persistence")

    /// Prefix of a sealed record. Its absence marks a conversation stored by an earlier version.
    nonisolated static var sealedMarker: String { "sealed-v1:" }

    private nonisolated struct Payload: Codable {
        let englishText: String
        let spanishText: String
    }

    /// False when the store on disk could not be opened and an in-memory one stands in for it.
    private let isPersistent: Bool

    init(context: ModelContext, sealer: any ConversationSealingProtocol, isPersistent: Bool = true) {
        self.context = context
        self.sealer = sealer
        self.isPersistent = isPersistent
    }

    func save(_ conversation: ConversationEntity) async throws {
        // Never pretend: a save to a store that will vanish at exit is a lost meeting. Failing
        // keeps the meeting on screen and its journal on disk.
        guard isPersistent else { throw ConversationStoreError.storeUnavailable }
        let sealed = try seal(english: conversation.englishText, spanish: conversation.spanishText)
        let record = ConversationRecord(id: conversation.id,
                                        englishText: sealed,
                                        spanishText: "",
                                        savedAt: conversation.savedAt)
        context.insert(record)
        try context.save()
        logger.info("💾 [Persistence] Saved sealed conversation id=\(conversation.id) bytes=\(sealed.utf8.count)")
    }

    func fetchSummaries() async throws -> [ConversationSummary] {
        var descriptor = FetchDescriptor<ConversationRecord>(
            sortBy: [SortDescriptor(\.savedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 500
        let records = try context.fetch(descriptor)
        logger.info("📋 [Persistence] Listed \(records.count) conversations")
        return records.map { ConversationSummary(id: $0.id, savedAt: $0.savedAt) }
    }

    func open(id: UUID, reason: String) async throws -> ConversationEntity {
        var descriptor = FetchDescriptor<ConversationRecord>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let record = try context.fetch(descriptor).first else {
            throw ConversationStoreError.notFound
        }
        let savedAt = record.savedAt
        let stored = record.englishText
        // Stored in clear by an earlier version and not sealed yet. It is sealed on the next launch.
        guard stored.hasPrefix(Self.sealedMarker) else { return record.toEntity() }

        guard let envelope = Data(base64Encoded: String(stored.dropFirst(Self.sealedMarker.count))) else {
            throw ConversationSealingError.unreadable
        }
        let plaintext = try await sealer.open(envelope, reason: reason)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: plaintext) else {
            throw ConversationSealingError.unreadable
        }
        return ConversationEntity(id: id,
                                  englishText: payload.englishText,
                                  spanishText: payload.spanishText,
                                  savedAt: savedAt)
    }

    @discardableResult
    func sealLegacyConversations() async throws -> Int {
        let records = try context.fetch(FetchDescriptor<ConversationRecord>())
        var sealedCount = 0
        for record in records where !record.englishText.hasPrefix(Self.sealedMarker) {
            record.englishText = try seal(english: record.englishText, spanish: record.spanishText)
            record.spanishText = ""
            sealedCount += 1
        }
        if sealedCount > 0 {
            try context.save()
            logger.notice("🔒 [Persistence] Sealed \(sealedCount) conversation(s) stored by an earlier version")
        }
        return sealedCount
    }

    private func seal(english: String, spanish: String) throws -> String {
        let plaintext = try JSONEncoder().encode(Payload(englishText: english, spanishText: spanish))
        return Self.sealedMarker + (try sealer.seal(plaintext)).base64EncodedString()
    }
}
