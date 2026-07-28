//
//  MonotonicClock.swift
//  TranslatorApp
//
//  The single time source for telemetry and pipeline windows
//  (008-fix-audio-pipeline-resilience, research §R3).
//
//  WHY THIS EXISTS
//  `DispatchTime.now().uptimeNanoseconds` STOPS while the device is asleep. Under decision Q3
//  — capturing with the screen locked — that stops being a detail: any gap measurement spanning
//  a sleep period would report less time than actually elapsed, and precisely in the scenario
//  Q3 introduces.
//
//  `ContinuousClock` keeps advancing across suspension, which is what "how much real time
//  passed" means. `SuspendingClock` has the opposite semantics and would be the classic mistake
//  here. `Date` is a wall clock: a time adjustment would produce negative deltas.
//

import Foundation

enum MonotonicClock {

    /// Built inline rather than held in a `static let`. With
    /// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a static stored property whose initializer
    /// is not a compile-time literal becomes MainActor-isolated, and reading it from an actor
    /// or from the audio thread would warn. `ContinuousClock` is an empty struct, so
    /// constructing it per call costs nothing.
    nonisolated static func now() -> ContinuousClock.Instant {
        ContinuousClock().now
    }

    /// Whole milliseconds elapsed since `instant`. Never negative.
    nonisolated static func msSince(_ instant: ContinuousClock.Instant) -> Int {
        milliseconds(from: instant, to: now())
    }

    /// Whole milliseconds between two instants. Never negative.
    nonisolated static func milliseconds(from start: ContinuousClock.Instant,
                                         to end: ContinuousClock.Instant) -> Int {
        guard end > start else { return 0 }
        let components = start.duration(to: end).components
        let fromSeconds = components.seconds * 1_000
        let fromAttoseconds = components.attoseconds / 1_000_000_000_000_000
        return Int(fromSeconds + fromAttoseconds)
    }
}
