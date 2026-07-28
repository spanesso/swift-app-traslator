//
//  PipelineTelemetryProtocol.swift
//  TranslatorApp
//
//  Domain-layer telemetry contract (008-fix-audio-pipeline-resilience, US1).
//  Implementation lives in Data/Telemetry/PipelineTelemetry.swift — gate G1.
//
//  DESIGN NOTE — deviation from contracts/PipelineTelemetryProtocol.swift
//  The Phase 1 contract sketched ~30 separate protocol requirements. That would force every
//  conformer (including the no-op used in tests) to restate 30 signatures, and adding a field
//  would be a breaking change across all of them. Instead the protocol has ONE requirement,
//  `emit(_:)`, and the named events are default implementations in an extension. Call sites
//  keep the same compile-time safety on names and field types; conformers implement one method.
//
//  Telemetry must NEVER alter the behaviour of the path it instruments: every method is
//  `nonisolated`, non-throwing, and non-blocking. If emission fails, it fails silently.
//

import Foundation

protocol PipelineTelemetryProtocol: Sendable {
    nonisolated func emit(_ event: TelemetryEvent)
}

/// No-op conformer for tests and for switching telemetry off without branching at call sites.
struct NoopPipelineTelemetry: PipelineTelemetryProtocol {
    nonisolated init() {}
    nonisolated func emit(_ event: TelemetryEvent) {}
}

// MARK: - Recognition session lifecycle (FR-001, FR-002)

extension PipelineTelemetryProtocol {

    nonisolated func sessionStart(_ sid: String, engineId: String, locale: String, onDevice: Bool) {
        emit(TelemetryEvent(kind: .sessionStart, sessionId: sid, fields: [
            .init("engine", engineId), .init("locale", locale), .init("onDevice", onDevice)
        ]))
    }

    /// The single most important event in this feature. Its absence is why no field report
    /// could previously be diagnosed: the recognition error was only ever compared against nil,
    /// so a server timeout, a network drop and a cancellation were indistinguishable.
    nonisolated func sessionEnd(_ sid: String,
                                reason: SessionEndReason,
                                errorDomain: String?,
                                errorCode: Int?,
                                durationMs: Int,
                                restartIndex: Int) {
        emit(TelemetryEvent(kind: .sessionEnd, sessionId: sid, fields: [
            .init("reason", reason.rawValue),
            .init("errDomain", errorDomain ?? "-"),
            .init("errCode", errorCode.map(String.init) ?? "-"),
            .init("durMs", durationMs),
            .init("restartIdx", restartIndex)
        ]))
    }

    nonisolated func restartBegin(_ sid: String, restartIndex: Int, trigger: RestartTrigger) {
        emit(TelemetryEvent(kind: .restartBegin, sessionId: sid, fields: [
            .init("restartIdx", restartIndex), .init("trigger", trigger.rawValue)
        ]))
    }

    nonisolated func restartEnd(_ sid: String,
                                restartIndex: Int,
                                outcome: RestartOutcome,
                                totalMs: Int,
                                carryOverBuffers: Int,
                                carryOverMs: Int) {
        emit(TelemetryEvent(kind: .restartEnd, sessionId: sid, fields: [
            .init("restartIdx", restartIndex),
            .init("outcome", outcome.rawValue),
            .init("totalMs", totalMs),
            .init("carryBuffers", carryOverBuffers),
            .init("carryMs", carryOverMs)
        ]))
    }

    /// A restart that failed leaving no live recognition task. Previously this produced only a
    /// generic error log that gave no hint the pipeline was now dead and the UI would never know.
    nonisolated func restartFailedFatal(_ sid: String,
                                        errorDomain: String,
                                        errorCode: Int,
                                        continuationStillOpen: Bool) {
        emit(TelemetryEvent(kind: .restartFailedFatal, sessionId: sid, fields: [
            .init("errDomain", errorDomain),
            .init("errCode", errorCode),
            .init("contOpen", continuationStillOpen)
        ]))
    }

    nonisolated func watchdogFired(_ sid: String, msSinceLastTranscript: Int, msSinceStart: Int) {
        emit(TelemetryEvent(kind: .watchdogFired, sessionId: sid, fields: [
            .init("sinceTranscriptMs", msSinceLastTranscript), .init("sinceStartMs", msSinceStart)
        ]))
    }
}

// MARK: - Audio continuity (FR-003)

extension PipelineTelemetryProtocol {

    /// Emit ONLY when the gap exceeds twice the nominal buffer duration. One line per buffer
    /// would flood the trace and make the log unusable for the ≤5-minute diagnosis target.
    nonisolated func audioGap(_ sid: String,
                              gapMs: Int,
                              expectedMs: Int,
                              bufferFrames: Int,
                              sampleRate: Double) {
        emit(TelemetryEvent(kind: .audioGap, sessionId: sid, fields: [
            .init("gapMs", gapMs),
            .init("expectedMs", expectedMs),
            .init("frames", bufferFrames),
            .init("rate", sampleRate, decimals: 0)
        ]))
    }

    /// Measures the blind window directly. With the permanent tap (research §R4) the expected
    /// value is 0 on every rotation — not "small", zero. Anything above 0 means a `removeTap`
    /// survived somewhere on the rotation path.
    nonisolated func tapSwap(_ sid: String, restartIndex: Int, blindWindowMs: Int, carryOverBuffers: Int) {
        emit(TelemetryEvent(kind: .tapSwap, sessionId: sid, fields: [
            .init("restartIdx", restartIndex),
            .init("blindMs", blindWindowMs),
            .init("carryBuffers", carryOverBuffers)
        ]))
    }

    nonisolated func tapFirstBuffer(_ sid: String, restartIndex: Int, msSinceInstall: Int) {
        emit(TelemetryEvent(kind: .tapFirstBuffer, sessionId: sid, fields: [
            .init("restartIdx", restartIndex), .init("sinceInstallMs", msSinceInstall)
        ]))
    }

    nonisolated func ringBufferState(_ sid: String, bufferedMs: Int, bufferCount: Int, evicted: Int) {
        emit(TelemetryEvent(kind: .ringBufferState, sessionId: sid, fields: [
            .init("bufferedMs", bufferedMs), .init("count", bufferCount), .init("evicted", evicted)
        ]))
    }
}
