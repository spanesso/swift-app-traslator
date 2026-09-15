//
//  AudioLevelMonitor.swift
//  TranslatorApp
//
//  Live input level, so a speaker the app cannot hear stops being invisible.
//
//  WHY THIS EXISTS
//  When someone at the far end of the table speaks quietly, the recogniser returns nothing and
//  the app simply stays silent. The user finds out at the end of the meeting, when that stretch
//  is missing. No amount of processing recovers audio that never reached the microphone — but it
//  can stop being lost WITHOUT ANYONE NOTICING, which is the difference between a problem you
//  can act on during the meeting and one you discover afterwards.
//
//  CONCURRENCY
//  Written from the real-time audio tap and read by the interface. Lock-protected rather than an
//  actor for the same reason as `AudioRingBuffer` and `RecognitionRequestBox`: the render thread
//  cannot `await`. The lock is held only across a few arithmetic operations — never across
//  allocation, I/O, or a suspension point.
//

import Foundation
import os

nonisolated final class AudioLevelMonitor: @unchecked Sendable {

    /// A reading of what the microphone is currently picking up.
    struct Reading: Sendable, Equatable {
        /// 0…1, mapped from dBFS over the range that matters for speech.
        let level: Float
        /// Loudest level seen in the recent window — survives between UI refreshes so a short
        /// word is not missed by a slow poll.
        let recentPeak: Float
        /// True when the recent window contains something loud enough to plausibly be speech.
        let hasSpeechEnergy: Bool

        nonisolated static var silent: Reading {
            Reading(level: 0, recentPeak: 0, hasSpeechEnergy: false)
        }
    }

    /// Below this there is nothing a recogniser could work with. Room noise sits well under it.
    private nonisolated static var speechFloorDb: Float { -45 }
    /// Quietest level worth showing on the meter at all.
    private nonisolated static var meterFloorDb: Float { -60 }
    /// How long a peak keeps counting towards `recentPeak`.
    private nonisolated static var peakWindowMs: Int { 1_500 }

    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var level: Float = 0
        var peak: Float = 0
        var peakAt: ContinuousClock.Instant?
        var speechSeenAt: ContinuousClock.Instant?
    }

    nonisolated init() {}

    /// Called from the audio tap, once per buffer. No allocation, no logging.
    nonisolated func record(samples: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        var sumOfSquares: Float = 0
        for index in 0..<count {
            let sample = samples[index]
            sumOfSquares += sample * sample
        }
        let rms = (sumOfSquares / Float(count)).squareRoot()
        record(rms: rms)
    }

    nonisolated func record(rms: Float) {
        let decibels = rms > 0 ? 20 * log10(rms) : Self.meterFloorDb
        let normalized = Self.normalize(decibels)
        let isSpeech = decibels > Self.speechFloorDb
        let now = MonotonicClock.now()

        state.withLock { current in
            current.level = normalized
            if normalized >= current.peak || Self.expired(current.peakAt, now: now) {
                current.peak = normalized
                current.peakAt = now
            }
            if isSpeech { current.speechSeenAt = now }
        }
    }

    /// Read by the interface. Cheap enough to poll several times a second.
    nonisolated func reading() -> Reading {
        let now = MonotonicClock.now()
        return state.withLock { current in
            let peak = Self.expired(current.peakAt, now: now) ? current.level : current.peak
            let speech = !Self.expired(current.speechSeenAt, now: now)
            return Reading(level: current.level, recentPeak: peak, hasSpeechEnergy: speech)
        }
    }

    nonisolated func reset() {
        state.withLock { current in current = State() }
    }

    // MARK: - Helpers

    private nonisolated static func expired(_ instant: ContinuousClock.Instant?,
                                            now: ContinuousClock.Instant) -> Bool {
        guard let instant else { return true }
        return MonotonicClock.milliseconds(from: instant, to: now) > peakWindowMs
    }

    /// Maps dBFS onto 0…1 across the range that carries speech. Linear in decibels, which is
    /// what makes a meter readable — a linear-in-amplitude meter barely moves for normal speech.
    private nonisolated static func normalize(_ decibels: Float) -> Float {
        guard decibels > meterFloorDb else { return 0 }
        return min(1, (decibels - meterFloorDb) / -meterFloorDb)
    }
}
