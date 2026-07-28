//
//  PipelineTelemetry+Events.swift
//  TranslatorApp
//
//  Named telemetry events for segmentation, translation, audio session and export.
//  Split from PipelineTelemetryProtocol.swift to keep both files under the 250-line convention.
//

import Foundation

// MARK: - Segmentation and endpointing (FR-004)

extension PipelineTelemetryProtocol {

    nonisolated func stabilityArmed(_ sid: String, delayMs: Int, reason: StabilityDelayReason, tailWords: Int) {
        emit(TelemetryEvent(kind: .stabilityArmed, sessionId: sid, fields: [
            .init("delayMs", delayMs), .init("reason", reason.rawValue), .init("tailWords", tailWords)
        ]))
    }

    /// Confirms or rules out the root cause of S2 on its own. A line with
    /// `rescheduled=false` and a non-empty pending tail IS the defect: the recogniser re-emits
    /// the same partial while the speaker pauses, and each repeat used to cancel the pending
    /// emission without ever arming it again.
    nonisolated func stabilityCancelled(_ sid: String,
                                        reason: StabilityCancelReason,
                                        rescheduled: Bool,
                                        pendingTailWords: Int,
                                        pendingAgeMs: Int) {
        emit(TelemetryEvent(kind: .stabilityCancelled, sessionId: sid, fields: [
            .init("reason", reason.rawValue),
            .init("rescheduled", rescheduled),
            .init("tailWords", pendingTailWords),
            .init("pendingMs", pendingAgeMs)
        ]))
    }

    nonisolated func stabilityFired(_ sid: String, armedToFiredMs: Int, tailWords: Int, emitted: Bool) {
        emit(TelemetryEvent(kind: .stabilityFired, sessionId: sid, fields: [
            .init("armedMs", armedToFiredMs), .init("tailWords", tailWords), .init("emitted", emitted)
        ]))
    }

    nonisolated func pendingAge(_ sid: String, pendingAgeMs: Int, pendingWords: Int, ceilingMs: Int) {
        emit(TelemetryEvent(kind: .pendingAge, sessionId: sid, fields: [
            .init("pendingMs", pendingAgeMs), .init("words", pendingWords), .init("ceilingMs", ceilingMs)
        ]))
    }

    nonisolated func asrRestartDetected(_ sid: String, incomingWords: Int, committedWords: Int) {
        emit(TelemetryEvent(kind: .asrRestartDetected, sessionId: sid, fields: [
            .init("incomingWords", incomingWords), .init("committedWords", committedWords)
        ]))
    }

    /// Directly observes the root cause of S3. A sustained run of `branch=wordCount` with a
    /// zero-length resulting buffer is the frozen-pane signature.
    nonisolated func uiPrefixMismatch(_ sid: String,
                                      branch: PrefixBranch,
                                      committedWordCount: Int,
                                      incomingWordCount: Int,
                                      resultingBufferChars: Int) {
        emit(TelemetryEvent(kind: .uiPrefixMismatch, sessionId: sid, fields: [
            .init("branch", branch.rawValue),
            .init("committedWords", committedWordCount),
            .init("incomingWords", incomingWordCount),
            .init("bufferChars", resultingBufferChars)
        ]))
    }
}

// MARK: - Translation queue (FR-005)

extension PipelineTelemetryProtocol {

    nonisolated func translationEnqueued(_ sid: String, fragmentId: Int, chars: Int, queueDepth: Int) {
        emit(TelemetryEvent(kind: .translationEnqueued, sessionId: sid, fields: [
            .init("frag", fragmentId), .init("chars", chars), .init("depth", queueDepth)
        ]))
    }

    nonisolated func translationStarted(_ sid: String, fragmentId: Int, queueDepth: Int, waitedMs: Int) {
        emit(TelemetryEvent(kind: .translationStarted, sessionId: sid, fields: [
            .init("frag", fragmentId), .init("depth", queueDepth), .init("waitedMs", waitedMs)
        ]))
    }

    nonisolated func translationDone(_ sid: String,
                                     fragmentId: Int,
                                     translateMs: Int,
                                     endToEndMs: Int,
                                     queueDepth: Int) {
        emit(TelemetryEvent(kind: .translationDone, sessionId: sid, fields: [
            .init("frag", fragmentId),
            .init("translateMs", translateMs),
            .init("e2eMs", endToEndMs),
            .init("depth", queueDepth)
        ]))
    }

    nonisolated func translationFailed(_ sid: String, fragmentId: Int, error: String, sourceChars: Int) {
        emit(TelemetryEvent(kind: .translationFailed, sessionId: sid, fields: [
            .init("frag", fragmentId), .init("err", error), .init("chars", sourceChars)
        ]))
    }

    nonisolated func translationSkipped(_ sid: String, fragmentId: Int, chars: Int, reason: String) {
        emit(TelemetryEvent(kind: .translationSkipped, sessionId: sid, fields: [
            .init("frag", fragmentId), .init("chars", chars), .init("reason", reason)
        ]))
    }

    nonisolated func translationDedupDropped(_ sid: String, fragmentId: Int) {
        emit(TelemetryEvent(kind: .translationDedup, sessionId: sid, fields: [.init("frag", fragmentId)]))
    }
}

// MARK: - Audio session (FR-006)

extension PipelineTelemetryProtocol {

    nonisolated func audioInterruption(_ sid: String,
                                       edge: InterruptionEdge,
                                       shouldResume: Bool,
                                       wasRecording: Bool) {
        emit(TelemetryEvent(kind: .audioInterruption, sessionId: sid, fields: [
            .init("edge", edge.rawValue),
            .init("shouldResume", shouldResume),
            .init("wasRecording", wasRecording)
        ]))
    }

    nonisolated func audioRouteChange(_ sid: String,
                                      reason: String,
                                      previousInput: String,
                                      newInput: String,
                                      previousSampleRate: Double,
                                      newSampleRate: Double,
                                      previousChannels: Int,
                                      newChannels: Int) {
        emit(TelemetryEvent(kind: .audioRouteChange, sessionId: sid, fields: [
            .init("reason", reason),
            .init("prevIn", previousInput), .init("newIn", newInput),
            .init("prevRate", previousSampleRate, decimals: 0),
            .init("newRate", newSampleRate, decimals: 0),
            .init("prevCh", previousChannels), .init("newCh", newChannels)
        ]))
    }

    nonisolated func audioConfigChange(_ sid: String,
                                       engineIsRunning: Bool,
                                       inputFormat: String,
                                       tapFormat: String,
                                       formatsMatch: Bool) {
        emit(TelemetryEvent(kind: .audioConfigChange, sessionId: sid, fields: [
            .init("running", engineIsRunning),
            .init("inFmt", inputFormat), .init("tapFmt", tapFormat),
            .init("match", formatsMatch)
        ]))
    }

    nonisolated func mediaServicesReset(_ sid: String, wasRecording: Bool) {
        emit(TelemetryEvent(kind: .mediaServicesReset, sessionId: sid, fields: [
            .init("wasRecording", wasRecording)
        ]))
    }

    nonisolated func audioSessionConfigured(_ sid: String,
                                            category: String,
                                            mode: String,
                                            options: String,
                                            sampleRate: Double,
                                            ioBufferDurationMs: Double,
                                            inputChannels: Int) {
        emit(TelemetryEvent(kind: .audioSessionConfig, sessionId: sid, fields: [
            .init("cat", category), .init("mode", mode), .init("opts", options),
            .init("rate", sampleRate, decimals: 0),
            .init("ioBufMs", ioBufferDurationMs),
            .init("inCh", inputChannels)
        ]))
    }

    nonisolated func scenePhaseChange(_ sid: String, phase: String, wasRecording: Bool, engineIsRunning: Bool) {
        emit(TelemetryEvent(kind: .scenePhase, sessionId: sid, fields: [
            .init("phase", phase), .init("wasRecording", wasRecording), .init("running", engineIsRunning)
        ]))
    }
}

// MARK: - Export (FR-033)

extension PipelineTelemetryProtocol {

    /// `enLines` and `esLines` must always be equal after this feature: a fragment without a
    /// translation carries a marker and still occupies its line, so nothing is ever "missing".
    nonisolated func exportAlignment(_ sid: String, enLines: Int, esLines: Int, unavailable: Int) {
        emit(TelemetryEvent(kind: .exportAlignment, sessionId: sid, fields: [
            .init("enLines", enLines),
            .init("esLines", esLines),
            .init("unavailable", unavailable),
            .init("aligned", enLines == esLines)
        ]))
    }
}
