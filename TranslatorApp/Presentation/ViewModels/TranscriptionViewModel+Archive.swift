//
//  TranscriptionViewModel+Archive.swift
//  TranslatorApp
//
//  What happens to a meeting once it ends (2026-09-15, replacing 010's automatic archiving).
//  Split from TranscriptionViewModel+Fragments.swift to keep both under 250 lines.
//
//  THE USER DECIDES. A finished meeting is neither saved nor discarded on its own. It stays on
//  screen and can be shared right away; the user saves it — sealed, as a whole, so only they can
//  open it again — or discards it after confirming. Until they decide, the journal on disk is
//  the copy that survives a crash, and recovery offers it again on the next launch. The
//  conversation is never lost without an explicit choice.
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

    /// A finished meeting the user has not decided about yet: on screen, shareable, not saved,
    /// and not lost.
    var hasUnsavedMeeting: Bool {
        sessionState == .idle && !fragments.isEmpty && !isArchived
    }

    // MARK: - End of meeting

    /// Called when a recording ends. Deliberately saves nothing and discards nothing.
    func meetingDidEnd() async {
        guard !fragments.isEmpty else {
            // Nothing was said: there is nothing to decide about, and nothing to recover.
            await journal.discard()
            return
        }
        logger.info("[ViewModel] meeting ended with \(self.fragments.count) fragment(s); waiting for the user to save, share or discard")
    }

    // MARK: - Save

    func saveConversation() async {
        guard canSave, !isSaving, !isArchived else { return }
        guard await persistMeeting() else { return }
        savedSuccessfully = true
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        savedSuccessfully = false
    }

    /// Seals and stores the whole meeting once. The journal is deleted only after the store has
    /// accepted it; on any failure it stays, and so does the meeting.
    @discardableResult
    func persistMeeting() async -> Bool {
        guard !fragments.isEmpty, !isArchived else { return isArchived }
        isSaving = true
        defer { isSaving = false }
        // Translations still arriving — a recovered meeting being re-translated — get their
        // bounded moment, so they are sealed with the meeting instead of arriving after it.
        if pendingCount > 0 { await drainPendingTranslations() }

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

        do {
            try await saveConversationUseCase.execute(englishText: english, spanishText: spanish)
            isArchived = true
            await journal.discard()
            if unavailable == fragments.count {
                errorMessage = "Saved, but no phrase could be translated in this session."
                hasError = true
            }
            logger.info("[ViewModel] meeting saved sealed (\(self.fragments.count) fragments)")
            return true
        } catch ConversationError.emptyTranscript {
            errorMessage = "Nothing to save — no speech was captured."
        } catch ConversationError.misalignedBlocks {
            errorMessage = "Save failed: the transcript and translation are out of step. The meeting is still here."
        } catch {
            errorMessage = "Save failed: \(error.localizedDescription) The meeting is still here and will be offered again if the app closes."
        }
        hasError = true
        logger.error("[ViewModel] save failed; the meeting and its journal are kept")
        return false
    }

    /// From the new-recording confirmation: the meeting on screen is saved first, and the new
    /// recording starts only if that worked.
    func saveAndStartNewSession() {
        pendingNewSessionConfirmation = false
        Task {
            guard await persistMeeting() else { return }
            startRecording()
        }
    }

    // MARK: - Discard

    func requestDiscard() {
        guard hasUnsavedMeeting else { return }
        pendingDiscardConfirmation = true
    }

    /// Only ever reached through an explicit confirmation in the interface.
    func discardConversation() {
        pendingDiscardConfirmation = false
        guard !isRecording else { return }
        fragments.removeAll()
        recentPhrases.reset()
        pendingFragmentCount = 0
        nextFragmentId = 0
        currentBuffer = ""
        isArchived = false
        Task { [journal] in await journal.discard() }
        logger.notice("[ViewModel] meeting discarded by the user")
    }
}
