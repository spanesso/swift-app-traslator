//
//  TranscriptionViewModel+Recovery.swift
//  TranslatorApp
//
//  Bringing back a meeting the app never got to finish (010-transcript-durability, US2).
//  Split from TranscriptionViewModel.swift to keep both under the 250-line convention.
//
//  Persisting without being able to recover would solve nothing: US1 and US2 are the same
//  promise seen from the two sides.
//

import SwiftUI
import OSLog

@MainActor
extension TranscriptionViewModel {

    /// Looks for a meeting left behind by a previous run. Called when the interface appears.
    func checkForRecoverableSession() async {
        guard fragments.isEmpty, !isRecording else { return }
        let pending = await journal.pendingSession()
        let recoverable = (pending?.isEmpty == false) ? pending : nil
        // Audio a crash left behind outlives its meeting otherwise. The one meeting the user has
        // still to decide about keeps its own.
        await shredOrphanedAudio(keeping: recoverable?.sessionId)
        guard let recovered = recoverable else { return }
        recoverableSession = recovered
        logger.notice("[ViewModel] found a recoverable session with \(recovered.fragments.count) fragment(s)")
    }

    /// Brings the recovered meeting back on screen. It behaves like any other finished session:
    /// the user saves, shares or discards it, and its journal stays on disk until they decide.
    func recoverPendingSession() {
        guard let recovered = recoverableSession else { return }
        // Translation is on-device and can simply be done again. A phrase recovered without its
        // Spanish — it was still being translated when the app died — is requested again instead
        // of staying "unavailable" for good (durability audit 2026-09-15, R8).
        fragments = recovered.fragments.map { fragment in
            var fragment = fragment
            if fragment.translation == .unavailable(.timedOut) { fragment.translation = .pending }
            return fragment
        }
        pendingFragmentCount = fragments.filter(\.isPending).count
        recentPhrases.reset()
        nextFragmentId = (recovered.fragments.map(\.id).max() ?? -1) + 1
        sessionId = recovered.sessionId
        isArchived = false
        currentBuffer = ""
        recoverableSession = nil
        if pendingFragmentCount > 0 {
            openTranslationStream()
            requeuePendingTranslations()
        }
        logger.info("[ViewModel] recovered session restored to screen (\(self.pendingFragmentCount) translation(s) requested again)")
    }

    /// Starts recording only when no earlier meeting is waiting in the journal.
    ///
    /// A leftover journal used to make the new meeting fail to open its own, so nothing of the new
    /// meeting was durable. Now the earlier meeting must be recovered or discarded first. A journal
    /// that exists but cannot be read is set aside, never deleted: "cannot read it now" is not
    /// "there is nothing in it" (durability audit 2026-09-15, R4).
    func startRecordingUnlessAMeetingIsPending() {
        Task { [journal] in
            if let recovered = await journal.pendingSession(), !recovered.isEmpty {
                self.recoverableSession = recovered
                return
            }
            if await journal.hasPendingSession() { await journal.setAsideUnreadable() }
            guard !self.isRecording else { return }
            self.startRecording()
        }
    }

    /// Throws the recovered meeting away. Only ever reached through an explicit confirmation in
    /// the interface (FR-012).
    func discardPendingSession() {
        pendingRecoveryDiscardConfirmation = false
        let discardedSessionId = recoverableSession?.sessionId
        recoverableSession = nil
        Task { [journal, meetingAudio] in
            await journal.discard()
            if let discardedSessionId { await meetingAudio.shred(sessionId: discardedSessionId) }
        }
        logger.notice("[ViewModel] recovered session discarded by the user")
    }
}
