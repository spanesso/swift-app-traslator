//
//  TapStallDetector.swift
//  TranslatorApp
//
//  Tells a microphone that stopped delivering audio apart from a quiet room
//  (research 2026-09-15, finding A3).
//
//  A quiet room still produces buffers — full of near-silence, but buffers. A capture path that
//  died (a media services reset, an engine stopped by a configuration change) produces none, and
//  nothing in the app was able to see it: `AUDIO_GAP` needs a next buffer to measure a gap, and
//  `RECOGNIZER_DEAF` needs speech energy. Pure, so it is testable without a microphone.
//

import Foundation

nonisolated struct TapStallDetector: Sendable {

    nonisolated enum Event: Equatable, Sendable {
        /// No buffer for at least `thresholdMs`. Reported once per stall.
        case stalled(silentMs: Int)
        /// Buffers are arriving again after a reported stall.
        case recovered(afterMs: Int)
    }

    /// Several nominal buffer periods, and more than any legitimate hiccup.
    nonisolated static var thresholdMs: Int { 2_000 }

    private var silentMs = 0
    private var isReported = false

    nonisolated init() {}

    /// Feed one sampling interval: how many buffers reached the tap during it.
    nonisolated mutating func observe(buffers: Int, intervalMs: Int) -> Event? {
        guard buffers == 0 else {
            let event: Event? = isReported ? .recovered(afterMs: silentMs) : nil
            silentMs = 0
            isReported = false
            return event
        }
        silentMs += intervalMs
        guard !isReported, silentMs >= Self.thresholdMs else { return nil }
        isReported = true
        return .stalled(silentMs: silentMs)
    }

    nonisolated mutating func reset() {
        silentMs = 0
        isReported = false
    }
}
