//
//  TranscriptionViewModel+Shutdown.swift
//  TranslatorApp
//
//  Ending, restarting and failing a recording session without losing its last words
//  (research 2026-09-15, finding P1).
//  Split from TranscriptionViewModel+Session.swift to keep both files under the 250-line convention.
//
//  THE ORDER THAT MATTERS
//  The consumer of the segmenter used to be cancelled FIRST and the pipeline stopped afterwards.
//  The segmenter's trailing flush — the phrase the speaker was finishing when the user pressed
//  stop — was then emitted into a stream nobody was reading. Now the pipeline is stopped first and
//  the consumer is given a bounded moment to commit whatever the flush produces.
//

import OSLog
import SwiftUI

@MainActor
extension TranscriptionViewModel {

    /// How long a stop waits for the recogniser's last result to become a fragment. Covers the
    /// engine's own wait for its final result plus the flush behind it.
    nonisolated static var shutdownFlushBudgetMs: Int { 2_500 }

    func stopRecording() {
        // The user's tap and the transcription task's completion can both land here; the field
        // log showed a duplicate SESSION_END from exactly that race.
        guard sessionState == .active || sessionState.isSuspended else { return }
        let epoch = sessionEpoch
        sessionState = .stopping
        let consumer = transcriptionTask
        transcriptionTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.transcribeUseCase.stop()
            await TaskCompletion.wait(for: consumer, upToMs: Self.shutdownFlushBudgetMs)
            // The last phrase is committed by now; a draft still scheduled would only repeat it.
            self.resetDraft()
            // Shutting the engine down takes time, and the user can start a new meeting while it
            // happens. Everything below belongs to the session that ENDED — applied to the new
            // one it closed its request stream and marked its phrases as timed out.
            guard self.sessionEpoch == epoch else { return }
            // Whatever is still on screen and was never committed becomes the last phrase — and
            // is queued for translation before the drain below.
            self.commitUnconfirmedTail()
            await self.drainPendingTranslations()
            guard self.sessionEpoch == epoch else { return }
            self.translationContinuation?.finish()
            self.translationContinuation = nil
            self.translationRequests = nil
            self.translationStreamId = nil
            self.sessionState = .idle
            self.translatorState = .idle
            self.stopLevelPolling()
            // Nothing is saved or discarded here: the user decides. The journal keeps the meeting
            // safe until they do (2026-09-15).
            await self.meetingDidEnd()
        }
    }

    /// Manual restart. The 300 ms sleep this used to contain is gone: it deterministically threw
    /// away a third of a second of audio with the engine already stopped, and the recogniser
    /// rotation path (which loses nothing) does the same job.
    ///
    /// The request stream is NOT closed here. Closing it ended the translation consumer, and
    /// because `isRecording` stays true across a restart nothing ever created a new one — the
    /// Spanish pane was dead from that tap onwards. `startRecording` replaces the stream and
    /// publishes a new `translationStreamId`, which is what the interface follows.
    func restartListening() {
        guard isRecording, !isRestartingListening else { return }
        isRestartingListening = true
        let consumer = transcriptionTask
        transcriptionTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.transcribeUseCase.stop()
            await TaskCompletion.wait(for: consumer, upToMs: Self.shutdownFlushBudgetMs)
            // The restart resets the live text; anything uncommitted on screen is kept first.
            self.commitUnconfirmedTail()
            self.isRestartingListening = false
            // The user may have stopped while the pipeline was being replaced.
            guard self.isRecording else { return }
            self.startRecording(preservingSession: true)
        }
    }

    /// Closes a session that ended in failure instead of by the user stopping it.
    ///
    /// These paths used to set `.idle` and stop there: the request stream stayed open with no
    /// consumer, the level meter kept polling, the meeting was never offered to the user, and every phrase
    /// already on screen kept its spinner for good. The failure was announced once in an alert
    /// and from then on was indistinguishable from a translation still in flight.
    func teardownAfterFailure() {
        let epoch = sessionEpoch
        translationContinuation?.finish()
        translationContinuation = nil
        translationRequests = nil
        translationStreamId = nil
        stopLevelPolling()
        Task { [weak self] in
            guard let self, self.sessionEpoch == epoch else { return }
            await self.drainPendingTranslations()
            guard self.sessionEpoch == epoch else { return }
            await self.meetingDidEnd()
        }
    }
}
