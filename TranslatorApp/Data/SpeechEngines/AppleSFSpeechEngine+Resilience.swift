//
//  AppleSFSpeechEngine+Resilience.swift
//  TranslatorApp
//
//  Reaction to audio-system events (008-fix-audio-pipeline-resilience, US5).
//  Split from AppleSFSpeechEngine.swift to keep both files under the 250-line convention.
//
//  THE RULE THAT MATTERS
//  An interruption SUSPENDS the session. It does not end it. The stream stays open, the history
//  is untouched, and the audio session stays active — that combination is what makes resuming a
//  resume rather than a restart, and it is what stops an alarm nobody attends to from silently
//  costing the user a stretch of the meeting.
//

import AVFoundation
import OSLog
import Speech

extension AppleSFSpeechEngine {

    /// Consumes audio-session events for the lifetime of the recording session.
    func startResilienceLoop() {
        resilienceTask?.cancel()
        let events = sessionCoordinator.eventStream()
        resilienceTask = Task { [weak self] in
            for await event in events {
                guard let self, await !self.isFinished else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: AudioSessionEvent) async {
        switch event {
        case .interrupted(let reason):      await suspend(reason: reason)
        case .resumed:                      await resume()
        case .captureNeedsRebuild(let why): await rebuild(reason: why)
        case .giveUp(let afterMs):          giveUp(afterMs: afterMs)
        }
    }

    // MARK: - Suspend / resume

    /// Stops the audio engine but keeps everything else alive. Note what is NOT done here:
    /// the stream is not finished, the history is not cleared, and the audio session is not
    /// deactivated (FR-030).
    private func suspend(reason: AudioInterruptionReason) async {
        guard !isSuspended, !isFinished else { return }
        isSuspended = true
        logger.warning("[AppleSFSpeech] suspended by \(reason.rawValue, privacy: .public)")
        await capture.stop()
        await sessionCoordinator.noteSuspended(reason: reason)
    }

    /// Resumes after an interruption ends — whether that was signalled by the system
    /// notification or discovered by the backup poll (research §R2).
    private func resume() async {
        guard isSuspended, !isFinished else { return }
        isSuspended = false
        await sessionCoordinator.noteResumed()
        do {
            try await sessionCoordinator.activate()
            try await capture.start(sessionId: sessionId)
            // A fresh request: the previous one has been starved of audio for the whole
            // interruption and its cumulative transcript is no longer meaningful.
            rotate(trigger: .manual)
            logger.info("[AppleSFSpeech] resumed after interruption")
        } catch {
            logger.error("[AppleSFSpeech] resume failed: \(error.localizedDescription, privacy: .public)")
            isSuspended = true
            await sessionCoordinator.noteSuspended(reason: .systemInterruption)
        }
    }

    // MARK: - Rebuild

    /// Route or configuration change: the input node's format changed, so the tap genuinely has
    /// to be reinstalled — the one case where touching it is correct (research §R4).
    private func rebuild(reason: AudioInterruptionReason) async {
        guard !isFinished else { return }
        do {
            try await capture.rebuildCapture(reason: reason)
            rotate(trigger: reason == .routeChanged ? .routeChange : .configChange)
            logger.info("[AppleSFSpeech] capture rebuilt after \(reason.rawValue, privacy: .public)")
        } catch {
            logger.error("[AppleSFSpeech] rebuild failed: \(error.localizedDescription, privacy: .public)")
            await suspend(reason: reason)
        }
    }

    // MARK: - Give up

    /// Reactivation kept failing past the ceiling. This is the only legitimate path out of a
    /// suspension other than resuming, and it is loud on purpose: the user must find out now,
    /// not when they look at the transcript later.
    private func giveUp(afterMs: Int) {
        guard !isFinished else { return }
        telemetry.sessionEnd(sessionId,
                             reason: .interruption,
                             errorDomain: "AudioSession",
                             errorCode: -1,
                             durationMs: afterMs,
                             restartIndex: restartCount)
        logger.error("[AppleSFSpeech] giving up after \(afterMs)ms suspended — ending stream")
        isFinished = true
        continuation?.finish()
        continuation = nil
    }
}
