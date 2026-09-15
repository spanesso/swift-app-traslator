//
//  PipelineTelemetry+Engine.swift
//  TranslatorApp
//
//  Engine selection and on-device model events (SpeechAnalyzer migration, 2026-09-15).
//

import Foundation

extension PipelineTelemetryProtocol {

    /// SpeechAnalyzer could not start and the classic recogniser was used instead. `reason` is an
    /// error domain and code — never text.
    ///
    /// ```
    /// grep '\[ENGINE_FALLBACK\]'   # empty on a supported device once the model is installed
    /// ```
    nonisolated func engineFallback(_ sid: String, from: String, to: String, reason: String) {
        emit(TelemetryEvent(kind: .engineFallback, sessionId: sid, fields: [
            .init("from", from), .init("to", to), .init("reason", reason)
        ]))
    }

    /// The app asked SpeechAnalyzer to finalise: at a `pause` in speech, or after a `longUtterance`.
    nonisolated func analyzerFinalize(_ sid: String, reason: String) {
        emit(TelemetryEvent(kind: .analyzerFinalize, sessionId: sid, fields: [.init("reason", reason)]))
    }

    /// The transcription model being downloaded TO the device: `downloading`, `installed`, `failed`.
    nonisolated func speechModel(_ sid: String, state: String) {
        emit(TelemetryEvent(kind: .speechModel, sessionId: sid, fields: [.init("state", state)]))
    }
}
