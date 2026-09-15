//
//  AppleSFSpeechEngine+Shutdown.swift
//  TranslatorApp
//
//  Ending a recording session without losing its last words (research 2026-09-15, finding P1).
//  Split from AppleSFSpeechEngine.swift to keep both files under the 250-line convention.
//
//  The stream used to be finished and the task cancelled BEFORE `endAudio()` was even called, so
//  whatever the recogniser had heard but not yet reported — typically the end of the last phrase
//  — was discarded on every stop. Now capture stops first, the request is told the audio is over,
//  and the recogniser gets a bounded moment to deliver its final result before the stream closes.
//

import Speech
import OSLog

extension AppleSFSpeechEngine {

    /// How long `stop()` waits for the recogniser's final result after `endAudio()`.
    nonisolated static var finalResultBudgetMs: Int { 1_500 }

    func stop() async {
        // Before the guard: `isStopping` stays true after a finished session until the next
        // start resets it, so a stop that lands while that start is still suspended would
        // otherwise return here without telling it.
        lifecycleEpoch += 1
        guard !isStopping else { return }
        isStopping = true
        logger.info("[AppleSFSpeech] stop (rotations=\(self.restartCount))")
        telemetry.sessionEnd(sessionId,
                             reason: .userStop,
                             errorDomain: nil,
                             errorCode: nil,
                             durationMs: MonotonicClock.msSince(sessionStartedAt),
                             restartIndex: restartCount)
        watchdogTask?.cancel(); watchdogTask = nil
        deafTask?.cancel(); deafTask = nil
        resilienceTask?.cancel(); resilienceTask = nil

        // No more audio reaches the request from here on.
        await capture.stop()

        if let lastRequest = requestBox.clear(), !isFinished {
            stopFinalReceived = false
            lastRequest.endAudio()
            await waitForFinalResult()
        }

        isFinished = true
        continuation?.finish(); continuation = nil
        recognitionTask?.cancel(); recognitionTask = nil
        await sessionCoordinator.stopObserving()
        await sessionCoordinator.deactivate()
        ringBuffer.reset()
    }

    /// A stop arrived while `start()` was suspended. Undoes what start had already done: without
    /// this the microphone kept capturing with the interface idle, and the next meeting began by
    /// replaying that audio (field log 2026-09-15: `SESSION_END sid=----` followed by a
    /// `SESSION_START` and `RINGBUFFER_STATE` lines with nobody recording).
    func abandonStart() async {
        logger.warning("[AppleSFSpeech] stop arrived while starting — capture abandoned")
        isFinished = true
        continuation?.finish(); continuation = nil
        await capture.stop()
        await sessionCoordinator.stopObserving()
        await sessionCoordinator.deactivate()
        ringBuffer.reset()
    }

    /// Polls rather than suspends on a continuation: the result arrives through `handleResult`,
    /// which runs on this actor while the loop sleeps, and a missing result must never hang stop.
    private func waitForFinalResult() async {
        let startedAt = MonotonicClock.now()
        while !stopFinalReceived, MonotonicClock.msSince(startedAt) < Self.finalResultBudgetMs {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        let waitedMs = MonotonicClock.msSince(startedAt)
        if stopFinalReceived {
            logger.info("[AppleSFSpeech] final result delivered \(waitedMs)ms after endAudio")
        } else {
            logger.warning("[AppleSFSpeech] no final result within \(waitedMs)ms of endAudio")
        }
    }
}

extension SFSpeechRecognizer {
    static func hasAuthorizationToRecognize() async -> Bool {
        await withCheckedContinuation { continuation in
            requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
}
