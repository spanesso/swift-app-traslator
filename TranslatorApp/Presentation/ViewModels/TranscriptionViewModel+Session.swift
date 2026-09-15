//
//  TranscriptionViewModel+Session.swift
//  TranslatorApp
//
//  Recording session start, suspension, and raw-stream handling
//  (008-fix-audio-pipeline-resilience, US2 and US5).
//  Split from TranscriptionViewModel.swift to keep both files under the 250-line convention.
//  Ending a session lives in TranscriptionViewModel+Shutdown.swift.
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

    /// - Parameters:
    ///   - preservingSession: a manual restart keeps the meeting on screen and in its journal.
    ///   - discardingUnsavedJournal: the user confirmed that an unsaved previous meeting may be
    ///     thrown away, so its journal is deleted before the new one is opened.
    func startRecording(preservingSession: Bool = false, discardingUnsavedJournal: Bool = false) {
        // Claims the session. Any shutdown still in flight checks this before it applies its
        // tail, so stopping and starting again in quick succession can no longer close the new
        // session's request stream.
        sessionEpoch += 1

        if !preservingSession {
            // Anything still on screen is discarded here. By this point the previous meeting is
            // already in the history (archived when it stopped) or the user has confirmed —
            // this is no longer a silent one-tap destruction (010 US3, US4).
            fragments.removeAll()
            recentPhrases.reset()
            nextFragmentId = 0
            sessionId = TelemetrySessionId.new()
            isArchived = false
            hasPersistenceFailure = false
            pendingFragmentCount = 0
            lastReportedBranch = nil
            recoverableSession = nil
            openJournal(for: sessionId, discardingPrevious: discardingUnsavedJournal)
        }
        reconciler.reset()
        resetDraft()
        lastSeenGeneration = 0
        currentBuffer = ""; errorMessage = nil; hasError = false
        translatorState = .idle; savedSuccessfully = false; latestSegmentConfidence = 1.0

        // Publishing a new stream is what creates the consumer. It must happen on EVERY start,
        // including a restart that preserves the session — `isRecording` does not change there.
        openTranslationStream()
        sessionState = .active
        startLevelPolling()

        // Phrases that were still waiting when the old stream was replaced went with it. They
        // are offered to the new consumer instead of keeping a spinner until the meeting ends.
        if preservingSession { requeuePendingTranslations() }

        // Everything this consumer does after an `await` is checked against the session it was
        // created for. A consumer outliving its session must never act on the next one.
        let epoch = sessionEpoch
        transcriptionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let (rawStream, stableStream) = try await self.transcribeUseCase.executeBoth()
                let uiTask = Task { @MainActor [weak self] in
                    for await segment in rawStream { self?.applyRawSegment(segment) }
                }
                for await phrase in stableStream { self.commitPhrase(phrase) }
                uiTask.cancel()
                // The pipeline ended by itself — the recogniser gave up, or an interruption was
                // abandoned. A restart ends it on purpose and must not be taken for that.
                if self.sessionEpoch == epoch, self.isRecording, !self.isRestartingListening {
                    self.stopRecording()
                }
            } catch let error as SpeechEngineError {
                guard self.sessionEpoch == epoch else { return }
                self.handleSpeechError(error)
            } catch is CancellationError {
                // The user stopped; `stopRecording` owns the shutdown. Reporting this as a
                // failure raised an alert for something that was not a failure.
                return
            } catch {
                guard self.sessionEpoch == epoch else { return }
                self.errorMessage = error.localizedDescription
                self.hasError = true
                self.translatorState = .error
                self.sessionState = .idle
                self.teardownAfterFailure()
            }
        }
    }

    /// Refreshes the input level ten times a second while recording.
    ///
    /// Polled rather than pushed: the level is written from the audio render thread, which cannot
    /// touch the main actor, and the interface does not need every buffer — it needs a meter that
    /// moves. `recentPeak` carries short words across refreshes so a quick "yes" is not missed by
    /// a slow poll.
    private func startLevelPolling() {
        levelPollTask?.cancel()
        levelPollTask = Task { [weak self, levelMonitor] in
            while !Task.isCancelled {
                let reading = levelMonitor.reading()
                // Only on a change: an unconditional write invalidated the whole screen ten
                // times a second for the entire meeting, silence included.
                await MainActor.run {
                    guard let self, self.inputLevel != reading else { return }
                    self.inputLevel = reading
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    /// Replaces the translation request stream. Closing the old one first means no consumer is
    /// ever left parked on a stream that never ends.
    func openTranslationStream() {
        translationContinuation?.finish()
        let (stream, continuation) = AsyncStream.makeStream(of: TranslationRequest.self)
        translationRequests = stream
        translationContinuation = continuation
        translationStreamId = UUID()
    }

    func closeTranslationStream() {
        translationContinuation?.finish()
        translationContinuation = nil
        translationRequests = nil
        translationStreamId = nil
    }

    func stopLevelPolling() {
        levelPollTask?.cancel()
        levelPollTask = nil
        inputLevel = .silent
    }

    /// Opens the durable journal for a new meeting.
    ///
    /// A journal left over from a previous run is never overwritten — if one is still there the
    /// recovery flow owns it, so we surface the problem instead of destroying evidence. The one
    /// exception is a meeting the user has explicitly agreed to discard.
    private func openJournal(for id: String, discardingPrevious: Bool) {
        Task { [journal, weak self] in
            do {
                if discardingPrevious { await journal.discard() }
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

        // The live text is the only copy of the phrase in progress. Keep it on disk.
        persistDraftSoon()
    }

    func handleSpeechError(_ error: SpeechEngineError) {
        switch error {
        case .notAuthorized:
            translatorState = .permissionDenied
            errorMessage = "Microphone or speech recognition access is required."
        case .onDeviceRecognitionUnavailable:
            translatorState = .error
            errorMessage = "Offline speech recognition is not available on this device, so recording did not start. Nothing was sent anywhere."
        default:
            translatorState = .error
            errorMessage = "Could not start the audio engine. Please try again."
        }
        hasError = true
        sessionState = .idle
        teardownAfterFailure()
    }
}
