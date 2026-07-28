//
//  PipelineTelemetry.swift
//  TranslatorApp
//
//  OSLog-backed implementation of PipelineTelemetryProtocol
//  (008-fix-audio-pipeline-resilience, US1).
//
//  DESIGN NOTE — deviation from plan.md, which said "actor"
//  This is a `Sendable` final class, not an actor, and the difference matters. An actor would
//  force `await` at every call site, which (a) makes emission impossible from the audio render
//  thread, where AUDIO_GAP has to be measured, and (b) violates the rule that telemetry must
//  never alter the timing of the path it instruments. `Logger` is already thread-safe and
//  Sendable, so wrapping it in an actor buys nothing and costs a hop per event.
//
//  Format: one line per event, `[KIND] sid=A1B2 key=value …` (research §R7). Emitted at
//  `.info` so it survives in the device log without a special build, which is what makes the
//  ≤5-minute field diagnosis (SC-026) possible.
//

import Foundation
import OSLog

final class PipelineTelemetry: PipelineTelemetryProtocol {
    private let logger: Logger

    nonisolated init(subsystem: String = "com.spanesso.TraslatorApp", category: String = "Telemetry") {
        self.logger = Logger(subsystem: subsystem, category: category)
    }

    /// Non-throwing, non-blocking, no actor hop. If emission fails it fails silently — telemetry
    /// never gets to break the pipeline it observes.
    ///
    /// `privacy: .public` is deliberate and safe: `TelemetryEvent` carries only counts,
    /// durations, identifiers and error codes. Transcribed text never reaches this type.
    nonisolated func emit(_ event: TelemetryEvent) {
        logger.info("\(event.line, privacy: .public)")
    }
}
