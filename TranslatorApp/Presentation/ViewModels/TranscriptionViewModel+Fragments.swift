//
//  TranscriptionViewModel+Fragments.swift
//  TranslatorApp
//
//  Fragment commit, translation resolution, drain, save and export
//  (008-fix-audio-pipeline-resilience, US7).
//  Split from TranscriptionViewModel.swift to keep both files under the 250-line convention.
//

import SwiftUI
import OSLog

@MainActor
extension TranscriptionViewModel {

    // MARK: - Commit

    /// Turns a stable phrase from the segmenter into a fragment and queues its translation.
    ///
    /// Deduplication happens HERE, once, on the fragment — using the normalised key that used
    /// to be applied only to the Spanish side. The old asymmetry (exact string match for
    /// English, case/diacritic/punctuation-insensitive for Spanish) meant two phrases differing
    /// only in punctuation produced two English entries and one Spanish one, permanently
    /// shifting every later pairing.
    func commitPhrase(_ phrase: SegmentedPhrase) {
        let trimmed = phrase.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let key = Self.dedupKey(trimmed)
        guard key.isEmpty || fragmentKeys.insert(key).inserted else {
            telemetry.translationDedupDropped(sessionId, fragmentId: nextFragmentId)
            return
        }

        let fragment = ConversationFragment(id: nextFragmentId,
                                            sourceText: trimmed,
                                            translation: .pending,
                                            sourceConfidence: phrase.confidence)
        nextFragmentId += 1
        // Full session history, never trimmed (FR-012, decision carried over from feature 007).
        fragments.append(fragment)

        // Advance the live-tail baseline. Omitting this left `committedWords` at 0 for the whole
        // session, so the green live text in the English pane was the entire cumulative
        // transcript growing without end instead of just the uncommitted tail.
        reconciler.commit(trimmed)

        translatorState = .inFlight
        telemetry.translationEnqueued(sessionId,
                                      fragmentId: fragment.id,
                                      chars: trimmed.count,
                                      queueDepth: pendingCount)
        translationContinuation?.yield(TranslationRequest(fragmentId: fragment.id,
                                                          text: trimmed,
                                                          sourceConfidence: phrase.confidence))
    }

    // MARK: - Translation resolution

    /// Routes a translation result back to its fragment by id.
    ///
    /// EVERY path resolves the fragment — success, failure, empty, too short. A fragment is
    /// never left dangling and never removed, which is what makes the line counts of the two
    /// exported blocks equal by construction (SC-020, SC-021).
    func resolveTranslation(fragmentId: Int, outcome: TranslationOutcome) {
        guard let index = fragments.firstIndex(where: { $0.id == fragmentId }) else { return }
        guard fragments[index].isPending else { return }
        fragments[index].translation = outcome
        translatorState = pendingCount > 0 ? .inFlight : .idle
    }

    func markTranslationUnavailable(fragmentId: Int, reason: TranslationOutcome.Reason) {
        resolveTranslation(fragmentId: fragmentId, outcome: .unavailable(reason))
    }

    /// The translation service could not start, so nothing in this session can be translated.
    /// Resolving eagerly means the user finds out now rather than at export time.
    func markSessionTranslationUnavailable() {
        for index in fragments.indices where fragments[index].isPending {
            fragments[index].translation = .unavailable(.serviceUnavailable)
        }
        translatorState = .modelUnavailable
    }

    var pendingCount: Int { fragments.reduce(0) { $0 + ($1.isPending ? 1 : 0) } }

    /// Waits for in-flight translations when the user stops, then times out whatever is left.
    ///
    /// Previously the stream was closed immediately and any in-flight translation was lost
    /// without a trace. Now the wait is bounded and the leftovers are marked, not dropped.
    func drainPendingTranslations() async {
        let deadlineMs = 3_000
        let startedAt = MonotonicClock.now()
        while pendingCount > 0, MonotonicClock.msSince(startedAt) < deadlineMs {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let stranded = pendingCount
        for index in fragments.indices where fragments[index].isPending {
            fragments[index].translation = .unavailable(.timedOut)
        }
        if stranded > 0 {
            logger.notice("[ViewModel] drain timed out with \(stranded) fragment(s) unresolved")
        }
    }

    /// Normalises text for duplicate detection: case- and diacritic-insensitive, punctuation
    /// stripped, whitespace collapsed.
    static func dedupKey(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    // MARK: - Export

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

    func saveConversation() async {
        guard canSave, !isSaving else { return }
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
