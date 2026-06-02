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

    func execute() async throws -> [ConversationEntity] {
        try await repository.fetchAll()
    }
}
