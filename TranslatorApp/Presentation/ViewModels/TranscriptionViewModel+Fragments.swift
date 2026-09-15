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

        // Only an echo of what was JUST committed is a duplicate. This used to be a set of every
        // phrase in the meeting, so the second "Okay." of a meeting was dropped before it was
        // journaled (research 2026-09-15, P2).
        let key = Self.dedupKey(trimmed)
        guard key.isEmpty || !recentPhrases.isDuplicate(key, at: MonotonicClock.now()) else {
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
        pendingFragmentCount += 1

        // Advance the live-tail baseline. Omitting this left `committedWords` at 0 for the whole
        // session, so the green live text in the English pane was the entire cumulative
        // transcript growing without end instead of just the uncommitted tail.
        reconciler.commit(trimmed)

        // Make it durable NOW (010 FR-001). Until this existed, everything above lived only in
        // this array, and a force-quit, a background kill or one tap on the record button
        // destroyed the meeting.
        persist(.source(fragment, sessionId: sessionId, epochMs: Self.nowEpochMs()))

        translatorState = .inFlight
        telemetry.translationEnqueued(sessionId,
                                      fragmentId: fragment.id,
                                      chars: trimmed.count,
                                      queueDepth: pendingCount)
        translationContinuation?.yield(TranslationRequest(fragmentId: fragment.id,
                                                          text: trimmed,
                                                          sourceConfidence: phrase.confidence))
    }

    /// Offers still-unresolved phrases to a freshly created request stream.
    ///
    /// Replacing the stream discards whatever was queued in it. Those phrases are not lost — the
    /// English is already on screen and in the journal — but nothing would ever translate them,
    /// so they held a spinner until the meeting ended and were then written off as timed out.
    /// `resolveTranslation` ignores a fragment that is no longer pending, so a request that was
    /// in flight when the swap happened cannot resolve twice.
    func requeuePendingTranslations() {
        guard let continuation = translationContinuation else { return }
        var requeued = 0
        for fragment in fragments where fragment.isPending {
            continuation.yield(TranslationRequest(fragmentId: fragment.id,
                                                  text: fragment.sourceText,
                                                  sourceConfidence: fragment.sourceConfidence))
            requeued += 1
        }
        guard requeued > 0 else { return }
        translatorState = .inFlight
        logger.notice("[ViewModel] re-queued \(requeued) phrase(s) onto the new request stream")
    }

    // MARK: - Translation resolution

    /// Routes a translation result back to its fragment by id.
    ///
    /// EVERY path resolves the fragment — success, failure, empty, too short. A fragment is
    /// never left dangling and never removed, which is what makes the line counts of the two
    /// exported blocks equal by construction (SC-020, SC-021).
    func resolveTranslation(fragmentId: Int, outcome: TranslationOutcome) {
        guard let index = fragmentIndex(id: fragmentId) else { return }
        guard fragments[index].isPending else { return }
        fragments[index].translation = outcome
        pendingFragmentCount -= 1
        translatorState = pendingCount > 0 ? .inFlight : .idle
        // Re-translating a recovered meeting keeps a stream open without recording. Close it once
        // there is nothing left to translate.
        if pendingCount == 0, sessionState == .idle { closeTranslationStream() }

        // The translation is part of the meeting too (010 FR-002). Recovering the English
        // without the Spanish would only be half the promise.
        if let entry = TranscriptJournalEntry.translation(fragmentId: fragmentId,
                                                          outcome: outcome,
                                                          sessionId: sessionId,
                                                          epochMs: Self.nowEpochMs()) {
            persist(entry)
        }
    }

    // MARK: - Stall detection

    /// Arms a watchdog for the translation about to start.
    ///
    /// The translation queue is serial on purpose: calling `TranslationSession.translate`
    /// concurrently is not documented as safe, and a crash costs more than latency. The price is
    /// that one stuck call freezes the Spanish pane for the rest of the meeting. This does not
    /// work around that — it makes it visible, which is the difference between a mute failure
    /// and one the user can act on.
    func translationDidStart(fragmentId: Int) {
        translationWatchdog?.cancel()
        let startedAt = MonotonicClock.now()
        let thresholdNs = UInt64(Self.translationStallThresholdMs) * 1_000_000
        translationWatchdog = Task { [weak self] in
            try? await Task.sleep(nanoseconds: thresholdNs)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.reportTranslationStall(fragmentId: fragmentId,
                                             inFlightMs: MonotonicClock.msSince(startedAt))
            }
        }
    }

    /// The translation came back — stuck or not. Clears the watchdog and any stall it raised.
    func translationDidFinish(fragmentId: Int) {
        translationWatchdog?.cancel()
        translationWatchdog = nil
        if stalledTranslationId == fragmentId {
            stalledTranslationId = nil
            logger.notice("[ViewModel] stalled translation \(fragmentId) finally returned")
        }
    }

    func reportTranslationStall(fragmentId: Int, inFlightMs: Int) {
        guard stalledTranslationId != fragmentId else { return }
        stalledTranslationId = fragmentId
        telemetry.translationStalled(sessionId,
                                     fragmentId: fragmentId,
                                     inFlightMs: inFlightMs,
                                     queueDepth: pendingCount)
        logger.error("""
            [ViewModel] translation \(fragmentId) stalled after \(inFlightMs)ms — \
            the Spanish pane is stuck with \(self.pendingCount) phrase(s) waiting
            """)
    }

    // MARK: - Durability

    /// Writes an entry to the journal off the main actor, and surfaces a failure rather than
    /// swallowing it — the only thing worse than losing the text is losing it silently
    /// (010 FR-005, FR-007).
    func persist(_ entry: TranscriptJournalEntry) {
        Task { [journal, weak self] in
            do {
                try await journal.record(entry)
            } catch {
                await MainActor.run { self?.reportPersistenceFailure(error) }
            }
        }
    }

    func reportPersistenceFailure(_ error: Error) {
        guard !hasPersistenceFailure else { return }   // one warning per session, not a storm
        hasPersistenceFailure = true
        errorMessage = (error as? TranscriptJournalError)?.errorDescription
            ?? "The transcript could not be saved to disk."
        hasError = true
        logger.error("[ViewModel] persistence failed: \(error.localizedDescription, privacy: .public)")
    }

    nonisolated static func nowEpochMs() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
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
        pendingFragmentCount = 0
        translatorState = .modelUnavailable
    }

    /// Maintained incrementally. It used to be a `reduce` over every fragment, called four
    /// times per phrase plus thirty times during the stop drain — O(n) work on the main actor
    /// that grew with the meeting.
    var pendingCount: Int { pendingFragmentCount }

    /// Fragments are appended with contiguous ids, so this is a binary search rather than the
    /// linear `firstIndex` it replaces. It also stays correct if recovery leaves a gap.
    func fragmentIndex(id: Int) -> Int? {
        var low = 0
        var high = fragments.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let candidate = fragments[mid].id
            if candidate == id { return mid }
            if candidate < id { low = mid + 1 } else { high = mid - 1 }
        }
        return nil
    }

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
        pendingFragmentCount = 0
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
}
