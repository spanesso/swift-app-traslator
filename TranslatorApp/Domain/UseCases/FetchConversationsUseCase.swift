//
//  FetchConversationsUseCase.swift
//  TranslatorApp
//

import Foundation

final class FetchConversationsUseCase {
    private let repository: ConversationRepositoryProtocol

    init(repository: ConversationRepositoryProtocol) {
        self.repository = repository
    }

    /// Summaries only. Listing the history never decrypts anything (2026-09-15).
    func execute() async throws -> [ConversationSummary] {
        try await repository.fetchSummaries()
    }
}
