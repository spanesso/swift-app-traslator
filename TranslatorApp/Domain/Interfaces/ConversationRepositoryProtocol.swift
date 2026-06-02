//
//  ConversationRepositoryProtocol.swift
//  TranslatorApp
//

import Foundation

protocol ConversationRepositoryProtocol {
    func save(_ conversation: ConversationEntity) async throws
    func fetchAll() async throws -> [ConversationEntity]
}
