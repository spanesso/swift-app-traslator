//
//  FileTranscriptJournal+Recovery.swift
//  TranslatorApp
//
//  Rebuilding a meeting from its journal after the app went away (010, US2).
//  Split from FileTranscriptJournal.swift to keep both under the 250-line convention.
//

import Foundation
import OSLog

extension FileTranscriptJournal {

    func hasPendingSession() -> Bool {
        guard let url = try? journalURL(),
              let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int else {
            return false
        }
        return size > 0
    }

    func pendingSession() -> RecoveredSession? {
        guard let url = try? journalURL(),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }

        var sources: [Int: (text: String, confidence: Float)] = [:]
        var outcomes: [Int: TranslationOutcome] = [:]
        var drafts: [Int: (text: String, epochMs: Int)] = [:]
        var sessionId: String?
        var earliestEpochMs = Int.max
        var damagedLines = 0

        // Split on newlines and decode each line independently. A line that does not decode is
        // the torn tail of a killed write — dropping it costs one phrase and saves the rest.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(TranscriptJournalEntry.self, from: Data(line)) else {
                damagedLines += 1
                continue
            }
            sessionId = sessionId ?? entry.sessionId
            earliestEpochMs = min(earliestEpochMs, entry.epochMs)
            switch entry.kind {
            case .source:
                if let text = entry.sourceText {
                    sources[entry.fragmentId] = (text, entry.confidence ?? 1.0)
                }
            case .translation:
                if let outcome = entry.replayedOutcome { outcomes[entry.fragmentId] = outcome }
            case .draft:
                if let text = entry.sourceText, !text.isEmpty,
                   entry.epochMs >= (drafts[entry.fragmentId]?.epochMs ?? Int.min) {
                    drafts[entry.fragmentId] = (text, entry.epochMs)
                }
            }
        }

        // The phrase in progress when the app died: the newest draft past the last committed
        // phrase. Anything at or before it was committed, and the committed text wins.
        let lastCommittedId = sources.keys.max() ?? -1
        if let inProgress = drafts.filter({ $0.key > lastCommittedId }).max(by: { $0.key < $1.key }) {
            sources[inProgress.key] = (inProgress.value.text, 0.5)
        }

        if damagedLines > 0 {
            logger.warning("[Journal] discarded \(damagedLines) damaged entr\(damagedLines == 1 ? "y" : "ies")")
        }
        guard !sources.isEmpty, let sessionId else { return nil }

        // Ordered by fragment id, not by position in the file: entries may have been appended
        // out of order and it does not matter.
        let fragments = sources.keys.sorted().map { id -> ConversationFragment in
            let source = sources[id]!
            return ConversationFragment(id: id,
                                        sourceText: source.text,
                                        translation: outcomes[id] ?? .unavailable(.timedOut),
                                        sourceConfidence: source.confidence)
        }
        logger.info("[Journal] recovered \(fragments.count) fragment(s) from session \(sessionId, privacy: .public)")
        return RecoveredSession(sessionId: sessionId,
                                fragments: fragments,
                                startedAtEpochMs: earliestEpochMs == .max ? 0 : earliestEpochMs)
    }
}
