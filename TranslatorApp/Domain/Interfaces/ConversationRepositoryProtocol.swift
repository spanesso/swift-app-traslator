//
//  ConversationRepositoryProtocol.swift
//  TranslatorApp
//
//  Saved conversations (2026-09-15): stored sealed, listed without their content, opened only
//  by their user.
//

import Foundation

protocol ConversationRepositoryProtocol {
    /// Seals the whole conversation once and stores it. Nothing of its text is written in clear.
    func save(_ conversation: ConversationEntity) async throws
    /// What the history may show without opening anything: identity and date.
    func fetchSummaries() async throws -> [ConversationSummary]
    /// Decrypts one conversation. On a device this asks for the user first.
    func open(id: UUID, reason: String) async throws -> ConversationEntity
    /// Seals conversations stored in clear by earlier versions. Returns how many were sealed.
    @discardableResult
    func sealLegacyConversations() async throws -> Int
}

nonisolated enum ConversationStoreError: Error, LocalizedError, Equatable {
    case notFound
    /// The history store could not be opened at launch. Nothing can be saved to it.
    case storeUnavailable

    var errorDescription: String? {
        switch self {
        case .notFound:
            return "This conversation no longer exists."
        case .storeUnavailable:
            return "Saved conversations are unavailable right now. Export the meeting to keep a copy."
        }
    }
}
