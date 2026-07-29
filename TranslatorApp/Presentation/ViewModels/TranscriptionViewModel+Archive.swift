//
//  TranscriptionViewModel+Archive.swift
//  TranslatorApp
//
//  Archiving, saving and exporting the meeting (010-transcript-durability, US3).
//  Split from TranscriptionViewModel+Fragments.swift to keep both under 250 lines.
//
//  The meeting archives itself when recording stops. "Save" is a convenience, never the thing
//  that prevents data loss — depending on the user remembering it, with the destructive button
//  right next to it, is the design flaw this feature removes.
//

import SwiftUI
import OSLog

@MainActor
extension TranscriptionViewModel {

    var exportText: String {
        ConversationTextFormatter.exportDocument(fragments)
    }

    var exportDocument: ConversationExport {
        ConversationExport(content: exportText,
                           filename: "Conversation \(Self.exportDateFormatter.string(from: Date())).txt")
    }

    static var exportDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        return formatter
    }

    // MARK: - Save

    /// Archives the meeting without the user asking (010 US3).
    ///
    /// Runs when recording stops. Until this existed, "Save" was a manual, optional step sitting
    /// next to the button that destroyed the meeting — the product depended on the user
    /// remembering. The journal is cleared only after this succeeds (FR-017).
    func archiveIfNeeded() async {
        guard !fragments.isEmpty else {
            // Nothing said. Drop the journal rather than leaving an empty session to "recover".
            await journal.discard()
            return
        }
        guard !isArchived else { return }

        do {
            try await persistConversation()
            isArchived = true
            savedSuccessfully = true
            await journal.discard()
            logger.info("[ViewModel] session archived automatically (\(self.fragments.count) fragments)")
        } catch {
            // Keep the journal: it is now the only copy (FR-018).
            errorMessage = "The meeting could not be archived: \(error.localizedDescription). It will be offered for recovery next time you open the app."
            hasError = true
            logger.error("[ViewModel] auto-archive failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func persistConversation() async throws {
        let english = ConversationTextFormatter.englishBlock(fragments)
        let spanish = ConversationTextFormatter.spanishBlock(fragments)
        let unavailable = fragments.reduce(0) { count, fragment in
            if case .unavailable = fragment.translation { return count + 1 }
            return count
        }
        telemetry.exportAlignment(sessionId,
                                  enLines: ConversationTextFormatter.lineCount(english),
                                  esLines: ConversationTextFormatter.lineCount(spanish),
                                  unavailable: unavailable)
        try await saveConversationUseCase.execute(englishText: english, spanishText: spanish)
    }

    func saveConversation() async {
        guard canSave, !isSaving else { return }
        // Already archived when recording stopped. Saying so beats silently creating a duplicate
        // (010 FR-015).
        guard !isArchived else {
            savedSuccessfully = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savedSuccessfully = false
            return
        }
        isSaving = true
        defer { isSaving = false }

        let english = ConversationTextFormatter.englishBlock(fragments)
        let spanish = ConversationTextFormatter.spanishBlock(fragments)
        let unavailable = fragments.reduce(0) { count, fragment in
            if case .unavailable = fragment.translation { return count + 1 }
            return count
        }
        telemetry.exportAlignment(sessionId,
                                  enLines: ConversationTextFormatter.lineCount(english),
                                  esLines: ConversationTextFormatter.lineCount(spanish),
                                  unavailable: unavailable)

        if unavailable == fragments.count && !fragments.isEmpty {
            errorMessage = "Saved, but no phrase could be translated in this session."
            hasError = true
        }

        do {
            try await saveConversationUseCase.execute(englishText: english, spanishText: spanish)
            isArchived = true
            await journal.discard()
            savedSuccessfully = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            savedSuccessfully = false
        } catch ConversationError.emptyTranscript {
            errorMessage = "Nothing to save — no speech was captured."
            hasError = true
        } catch ConversationError.misalignedBlocks {
            errorMessage = "Save failed: the transcript and translation are out of step."
            hasError = true
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription)"
            hasError = true
        }
    }
}
