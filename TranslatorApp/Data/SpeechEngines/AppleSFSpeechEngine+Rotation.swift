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

    // MARK: - Recogniser callbacks

    func handleResult(request: SFSpeechAudioBufferRecognitionRequest,
                      text: String,
                      isFinal: Bool,
                      tokens: [TranscriptToken],
                      generation: Int,
                      ordinal: Int,
                      errorDomain: String?,
                      errorCode: Int?) async {
        guard !isFinished else { return }
        // A callback from a PREVIOUS recording session. `generation` restarts at 0 every session,
        // so it used to pass the check below: the old task's closing error rotated the fresh
        // request 24 ms into the next meeting (field log 2026-09-15).
        guard ordinal == sessionOrdinal else { return }
        // Ignore callbacks from a request a rotation already superseded.
        guard requestBox.isCurrent(request) || generation == self.generation else { return }

        if !text.isEmpty {
            lastTranscriptAt = MonotonicClock.now()
            consecutiveDeafRotations = 0
            if !isStopping {
                armWatchdog()
                armDeafWatchdog()
            }
            let confidence: Float = tokens.isEmpty
                ? 0.5
                : tokens.reduce(0) { $0 + $1.confidence } / Float(tokens.count)
            continuation?.yield(SpeechSegment(text: text,
                                              isFinal: isFinal,
                                              confidence: confidence,
                                              tokens: tokens,
                                              source: engineId,
                                              sessionGeneration: generation))
        }

        guard isFinal || errorDomain != nil else { return }

        // The last request of the session has closed. `stop()` is waiting for exactly this.
        guard !isStopping else {
            stopFinalReceived = true
            return
        }

        // A pause is not a failure. The recogniser reports "no speech detected" as an error, and
        // treating it as one made a meeting with natural silences look like an unstable session:
        // the restart count tracked the rhythm of the conversation, and real failures were buried
        // among them. The rotation still happens — the task really did end and the next request
        // starts from zero — but it is now labelled for what it is.
        let failure = RecognitionFailureKind.classify(domain: errorDomain, code: errorCode)
        let reason = failure?.sessionEndReason ?? .isFinal
        let trigger = failure?.restartTrigger ?? .isFinal

        telemetry.sessionEnd(sessionId,
                             reason: reason,
                             errorDomain: errorDomain,
                             errorCode: errorCode,
                             durationMs: MonotonicClock.msSince(sessionStartedAt),
                             restartIndex: restartCount)
        if failure == .failure {
            logger.error("[AppleSFSpeech] recognition failed \(errorDomain ?? "-", privacy: .public)/\(errorCode ?? -1)")
        }
        rotate(trigger: trigger)
    }

    // MARK: - Rotation

    func rotate(trigger: RestartTrigger) {
        guard !isRotating, !isFinished, !isSuspended, !isStopping else { return }
        isRotating = true
        defer { isRotating = false }

        restartCount += 1
        generation += 1
        let startedAt = MonotonicClock.now()
        telemetry.restartBegin(sessionId, restartIndex: restartCount, trigger: trigger)

        let oldTask = recognitionTask
        let carryOver: CarryOver
        do {
            carryOver = try startRecognitionTask(trigger: trigger)
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
        // Measured, not assumed: these were hardcoded to 0, so the log could never show whether
        // the replay actually covered anything.
        telemetry.restartEnd(sessionId,
                             restartIndex: restartCount,
                             outcome: .ok,
                             totalMs: MonotonicClock.msSince(startedAt),
                             carryOverBuffers: carryOver.buffers,
                             carryOverMs: carryOver.ms)
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
        guard !isFinished, !isRotating, !isSuspended, !isStopping else { return }
        telemetry.watchdogFired(sessionId,
                                msSinceLastTranscript: MonotonicClock.msSince(lastTranscriptAt),
                                msSinceStart: MonotonicClock.msSince(sessionStartedAt))
        logger.warning("[AppleSFSpeech] watchdog fired — forcing rotation")
        rotate(trigger: .watchdog)
    }

    // MARK: - Deaf-recogniser watchdog

    /// Watches for the state the long watchdog is not built to catch: the recogniser producing
    /// nothing while the microphone is still carrying speech.
    ///
    /// This is what a speaker change looks like in the field. `SFSpeechRecognizer` closes the
    /// utterance when the first speaker stops and — with on-device recognition on iOS 26 — does
    /// not always pick up the next one: no final result, no error, no rotation, and a task that
    /// is alive and silent. Fourteen seconds of a real meeting were lost that way with every
    /// other signal reporting health.
    ///
    /// Rotating is the remedy because rotation is free here: the tap is permanent, so `blindMs`
    /// is 0, and the new request is given everything since the last transcript (see
    /// `replayWindowMs`) — the speech the silent request heard and never turned into text.
    func armDeafWatchdog() {
        deafTask?.cancel()
        let timeoutMs = deafTimeoutMs()
        deafTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutMs) * 1_000_000)
            guard !Task.isCancelled else { return }
            await self?.deafWatchdogDidFire()
        }
    }

    /// Doubles per consecutive failed rotation, up to a ceiling. If re-creating the recogniser
    /// twice has not brought the text back, the problem is upstream of it — the microphone, or a
    /// speaker nobody can hear — and re-creating it every four seconds only burns battery.
    func deafTimeoutMs() -> Int {
        let scaled = Self.deafTimeoutMs << min(consecutiveDeafRotations, 4)
        return min(scaled, Self.deafBackoffCeilingMs)
    }

    func deafWatchdogDidFire() {
        guard !isFinished, !isStopping else { return }
        // Re-arm rather than return: an interruption or a rotation in flight is a reason to skip
        // THIS check, not to switch the watchdog off. Returning silently here would leave the
        // session unwatched for the rest of the meeting — nothing else re-arms it, because the
        // only other trigger is a transcript update and the whole point is that none arrive.
        guard !isRotating, !isSuspended else {
            armDeafWatchdog()
            return
        }

        let sinceTranscriptMs = MonotonicClock.msSince(lastTranscriptAt)
        let reading = levelMonitor.reading()

        // Silence is not deafness. Without this check the timeout would fire through every pause
        // in the conversation and rotate the recogniser for a living.
        guard reading.hasSpeechEnergy else {
            telemetry.recognizerDeaf(sessionId,
                                     msSinceLastTranscript: sinceTranscriptMs,
                                     level: reading.recentPeak,
                                     rotated: false,
                                     consecutive: consecutiveDeafRotations)
            armDeafWatchdog()
            return
        }

        consecutiveDeafRotations += 1
        telemetry.recognizerDeaf(sessionId,
                                 msSinceLastTranscript: sinceTranscriptMs,
                                 level: reading.recentPeak,
                                 rotated: true,
                                 consecutive: consecutiveDeafRotations)
        logger.warning("""
            [AppleSFSpeech] recogniser silent for \(sinceTranscriptMs)ms with speech-level audio \
            (peak \(String(format: "%.2f", reading.recentPeak))) — rotating
            """)
        rotate(trigger: .deaf)
    }
}
