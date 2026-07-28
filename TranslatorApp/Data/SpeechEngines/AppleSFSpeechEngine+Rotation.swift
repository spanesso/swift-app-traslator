//
//  AppleSFSpeechEngine+Rotation.swift
//  TranslatorApp
//
//  Recogniser rotation and the activity watchdog
//  (008-fix-audio-pipeline-resilience, US6).
//  Split from AppleSFSpeechEngine.swift to keep both files under the 250-line convention.
//
//  Rotation never touches the microphone tap: it swaps the request inside
//  RecognitionRequestBox, so no window exists in which nothing is capturing (research §R4).
//

import Speech
import OSLog

extension AppleSFSpeechEngine {

    func rotate(trigger: RestartTrigger) {
        guard !isRotating, !isFinished, !isSuspended else { return }
        isRotating = true
        defer { isRotating = false }

        restartCount += 1
        generation += 1
        let startedAt = MonotonicClock.now()
        telemetry.restartBegin(sessionId, restartIndex: restartCount, trigger: trigger)

        let oldTask = recognitionTask
        do {
            try startRecognitionTask(trigger: trigger)
        } catch {
            let nsError = error as NSError
            // The behaviour only one of the three old engines had: make the failure visible and
            // terminate the stream, instead of leaving an open continuation with no live task
            // and a UI that still believes it is recording.
            telemetry.restartFailedFatal(sessionId,
                                         errorDomain: nsError.domain,
                                         errorCode: nsError.code,
                                         continuationStillOpen: continuation != nil)
            telemetry.restartEnd(sessionId,
                                 restartIndex: restartCount,
                                 outcome: .failed,
                                 totalMs: MonotonicClock.msSince(startedAt),
                                 carryOverBuffers: 0,
                                 carryOverMs: 0)
            logger.error("[AppleSFSpeech] rotation failed — terminating stream")
            isFinished = true
            continuation?.finish(); continuation = nil
            return
        }
        oldTask?.cancel()
        telemetry.restartEnd(sessionId,
                             restartIndex: restartCount,
                             outcome: .ok,
                             totalMs: MonotonicClock.msSince(startedAt),
                             carryOverBuffers: 0,
                             carryOverMs: 0)
    }

    // MARK: - Watchdog

    /// Re-armed on every transcript update, not only when a session starts. The old version
    /// armed it once per rotation, so a session that legitimately outlived the timeout was
    /// rotated for no reason every 65 s — each rotation paying its own cost.
    func armWatchdog() {
        watchdogTask?.cancel()
        let timeout = watchdogTimeoutNs
        watchdogTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: timeout)
            guard !Task.isCancelled else { return }
            await self?.watchdogDidFire()
        }
    }

    func watchdogDidFire() {
        guard !isFinished, !isRotating, !isSuspended else { return }
        telemetry.watchdogFired(sessionId,
                                msSinceLastTranscript: MonotonicClock.msSince(lastTranscriptAt),
                                msSinceStart: MonotonicClock.msSince(sessionStartedAt))
        logger.warning("[AppleSFSpeech] watchdog fired — forcing rotation")
        rotate(trigger: .watchdog)
    }
}
