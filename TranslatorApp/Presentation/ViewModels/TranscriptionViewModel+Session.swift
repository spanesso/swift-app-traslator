//
//  TranscriptionViewModel+Session.swift
//  TranslatorApp
//
//  Recording session lifecycle, suspension, and raw-stream handling
//  (008-fix-audio-pipeline-resilience, US2 and US5).
//  Split from TranscriptionViewModel.swift to keep both files under the 250-line convention.
//

import OSLog
import SwiftUI

@MainActor
extension TranscriptionViewModel {

    // MARK: - Suspension (US5)

    func enterSuspended(reason: AudioInterruptionReason) {
        guard sessionState == .active else { return }
        sessionState = .suspended(reason)
        translatorState = .suspendedByAudioInterruption(reason)
        // Deliberately NOT setting hasError: this is a recoverable pause, not a failure, and
        // certainly not the permissions problem it used to be reported as.
        logger.warning("[ViewModel] suspended by \(reason.rawValue, privacy: .public)")
    }

    func leaveSuspended() {
        guard sessionState.isSuspended else { return }
        sessionState = .active
        translatorState = .idle
        logger.info("[ViewModel] resumed")
    }

    func abandonAfterInterruption(afterMs: Int) {
        guard sessionState.isSuspended else { return }
        errorMessage = "Recording stopped: the microphone stayed unavailable for \(afterMs / 1000)s."
        hasError = true
        translatorState = .error
        stopRecording()
    }

    // MARK: - Session lifecycle

    func startRecording(preservingSession: Bool = false) {
        if !preservingSession {
            // Anything still on screen is discarded here. By this point the previous meeting is
            // already in the history (archived when it stopped) and the user has confirmed —
            // this is no longer a silent one-tap destruction (010 US3, US4).
            fragments.removeAll()
            fragmentKeys.removeAll()
            nextFragmentId = 0
            sessionId = TelemetrySessionId.new()
            isArchived = false
            hasPersistenceFailure = false
            pendingFragmentCount = 0
            lastReportedBranch = nil
            recoverableSession = nil
            openJournal(for: sessionId)
        }
        reconciler.reset()
        lastSeenGeneration = 0
        currentBuffer = ""; errorMessage = nil; hasError = false
        translatorState = .idle; savedSuccessfully = false; latestSegmentConfidence = 1.0

        let (stream, continuation) = AsyncStream.makeStream(of: TranslationRequest.self)
        translationRequests = stream
        translationContinuation = continuation
        sessionState = .active

        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (rawStream, stableStream) = try await self.transcribeUseCase.executeBoth()
                let uiTask = Task { @MainActor [weak self] in
                    for await segment in rawStream { self?.applyRawSegment(segment) }
                }
                for await phrase in stableStream { self.commitPhrase(phrase) }
                uiTask.cancel()
                if self.isRecording { self.stopRecording() }
            } catch let error as SpeechEngineError {
                self.handleSpeechError(error)
            } catch {
                self.errorMessage = error.localizedDescription
                self.hasError = true
                self.translatorState = .error
                self.sessionState = .idle
            }
        }
    }

    func stopRecording() {
        // The user's tap and the transcription task's completion can both land here; the field
        // log showed a duplicate SESSION_END from exactly that race.
        guard sessionState == .active || sessionState.isSuspended else { return }
        sessionState = .stopping
        transcriptionTask?.cancel(); transcriptionTask = nil
        Task { [weak self] in
            guard let self else { return }
            await self.transcribeUseCase.stop()
            await self.drainPendingTranslations()
            self.translationContinuation?.finish()
            self.translationContinuation = nil
            self.translationRequests = nil
            self.sessionState = .idle
            self.translatorState = .idle
            // Archive BEFORE the user can touch anything else. The meeting must not depend on
            // them remembering to press Save (010 US3).
            await self.archiveIfNeeded()
        }
    }

    /// Opens the durable journal for a new meeting.
    ///
    /// A journal left over from a previous run is never overwritten — if one is still there the
    /// recovery flow owns it, so we surface the problem instead of destroying evidence.
    private func openJournal(for id: String) {
        Task { [journal, weak self] in
            do {
                try await journal.beginSession(id: id)
            } catch {
                await MainActor.run { self?.reportPersistenceFailure(error) }
            }
        }
    }

    // MARK: - Stream handling

    /// Live English tail. Delegates the hard part to `LiveTailReconciler`, and resets the
    /// reconciler's baseline when the segment's generation shows the recogniser rotated.
    func applyRawSegment(_ segment: SpeechSegment) {
        latestSegmentConfidence = segment.confidence

        if segment.sessionGeneration != lastSeenGeneration {
            lastSeenGeneration = segment.sessionGeneration
            reconciler.recognitionSessionDidRestart()
        }

        let result = reconciler.liveTail(from: segment.text)
        currentBuffer = result.tail

        // Report only when the branch CHANGES. This used to fire on every partial — three times
        // a second for the whole meeting — and each report split the recogniser's entire
        // cumulative text just to count its words, on the main actor.
        if result.branch != .hasPrefix, result.branch != lastReportedBranch {
            telemetry.uiPrefixMismatch(sessionId,
                                       branch: result.branch,
                                       committedWordCount: reconciler.committedWordCountInSession,
                                       incomingWordCount: -1,   // full count is not worth an O(n) scan here
                                       resultingBufferChars: result.tail.count)
        }
        lastReportedBranch = result.branch
    }

    func handleSpeechError(_ error: SpeechEngineError) {
        switch error {
        case .notAuthorized:
            translatorState = .permissionDenied
            errorMessage = "Microphone or speech recognition access is required."
        default:
            translatorState = .error
            errorMessage = "Could not start the audio engine. Please try again."
        }
        hasError = true
        sessionState = .idle
    }
}
