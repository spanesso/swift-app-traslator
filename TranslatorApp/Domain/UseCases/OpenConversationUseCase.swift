//
//  OpenConversationUseCase.swift
//  TranslatorApp
//
//  Opening a saved conversation (2026-09-15). Only its user can: on a device this asks for
//  Face ID, Touch ID or the passcode before anything is decrypted.
//

import Foundation

final class OpenConversationUseCase {
    private let repository: ConversationRepositoryProtocol

    init(repository: ConversationRepositoryProtocol) {
        self.repository = repository
    }

    func execute(id: UUID) async throws -> ConversationEntity {
        try await repository.open(id: id, reason: "Open your saved conversation")
    }
}
