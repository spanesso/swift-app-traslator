//
//  ConversationHistoryViewModel.swift
//  TranslatorApp
//
//  The saved-conversation history (2026-09-15). It lists conversations without reading them, and
//  holds the text of the ONE conversation the user unlocked only while it is on screen.
//

import SwiftUI
import OSLog

@MainActor
@Observable
final class ConversationHistoryViewModel {
    var conversations: [ConversationSummary] = []
    var isLoading: Bool = false
    var errorMessage: String? = nil
    /// The conversation the user unlocked. Cleared as soon as it leaves the screen.
    var openedConversation: ConversationEntity?
    /// The conversation being unlocked right now, so the list can show it.
    var openingId: UUID?

    private let fetchUseCase: FetchConversationsUseCase
    private let openUseCase: OpenConversationUseCase
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "History")

    init(fetchUseCase: FetchConversationsUseCase, openUseCase: OpenConversationUseCase) {
        self.fetchUseCase = fetchUseCase
        self.openUseCase = openUseCase
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
            logger.error("❌ [History] Load failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Asks the user to confirm it is them, then decrypts. Cancelling is not an error.
    func open(_ summary: ConversationSummary) async {
        guard openingId == nil else { return }
        openingId = summary.id
        defer { openingId = nil }
        do {
            openedConversation = try await openUseCase.execute(id: summary.id)
        } catch ConversationSealingError.cancelled {
            return
        } catch {
            errorMessage = error.localizedDescription
            logger.error("❌ [History] Open failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Drops the decrypted text. Called when the conversation or the history leaves the screen.
    func closeConversation() {
        openedConversation = nil
    }
}
