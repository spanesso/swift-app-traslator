//
//  PipelineTelemetry+Health.swift
//  TranslatorApp
//
//  Capture-path and device-health events (research 2026-09-15, phase 1).
//  Split from PipelineTelemetry+Events.swift to keep both files under the 250-line convention.
//

import Foundation

extension PipelineTelemetryProtocol {

    /// `state=stalled` means the engine is supposedly capturing and no buffer has reached the tap
    /// for `silentMs`. `state=recovered` closes it with the total duration.
    ///
    /// ```
    /// grep '\[TAP_STALL\]'   # must be EMPTY in a healthy meeting
    /// ```
    nonisolated func tapStall(_ sid: String, stalled: Bool, silentMs: Int, engineRunning: Bool) {
        emit(TelemetryEvent(kind: .tapStall, sessionId: sid, fields: [
            .init("state", stalled ? "stalled" : "recovered"),
            .init("silentMs", silentMs),
            .init("running", engineRunning)
        ]))
    }

    nonisolated func memoryWarning(_ sid: String, wasRecording: Bool) {
        emit(TelemetryEvent(kind: .memoryWarning, sessionId: sid, fields: [
            .init("wasRecording", wasRecording)
        ]))
    }

    /// `availMB` is `os_proc_available_memory()`: how close the app is to being terminated for
    /// memory, which is what matters on a 4 GB device. Always 0 on the simulator.
    nonisolated func resources(_ sid: String, thermal: String, availableMemoryMB: Int, reason: String) {
        emit(TelemetryEvent(kind: .resources, sessionId: sid, fields: [
            .init("thermal", thermal),
            .init("availMB", availableMemoryMB),
            .init("reason", reason)
        ]))
    }
}
