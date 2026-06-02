//
//  ConversationHistoryViewModel.swift
//  TranslatorApp
//

import SwiftUI
import OSLog

@MainActor
@Observable
final class ConversationHistoryViewModel {
    var conversations: [ConversationEntity] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil

    private let fetchUseCase: FetchConversationsUseCase
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "History")

    init(fetchUseCase: FetchConversationsUseCase) {
        self.fetchUseCase = fetchUseCase
    }

    func loadConversations() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            conversations = try await fetchUseCase.execute()
            logger.info("📋 [History] Loaded \(self.conversations.count) conversations")
        } catch {
            errorMessage = "Could not load conversations: \(error.localizedDescription)"
            logger.error("❌ [History] Load failed: \(error)")
        }
    }
}
