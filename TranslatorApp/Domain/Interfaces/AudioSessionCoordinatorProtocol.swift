//
//  AudioSessionCoordinatorProtocol.swift
//  TranslatorApp
//
//  Domain contract for the single owner of the system audio session
//  (008-fix-audio-pipeline-resilience, US5). Implementation: Data/Audio/AudioSessionCoordinator.
//
//  Previously this responsibility was split across three engines that configured the session
//  inconsistently, plus a loose observer in the composition root that listened only for the
//  START of an interruption and never removed itself. Route changes, configuration changes and
//  media-services resets were not observed at all.
//
//  Follows the `stateStream()` idiom already used by ModelDownloadCoordinatorProtocol.
//

import Foundation

protocol AudioSessionCoordinatorProtocol: Sendable {

    /// Events the recording layer must react to. Multiple consumers are supported.
    nonisolated func eventStream() -> AsyncStream<AudioSessionEvent>

    /// Correlation id shared with the recognition session, so audio-session events and
    /// recogniser events line up in the same log filter.
    func setSessionId(_ id: String) async

    /// Configures and activates the session. Idempotent. Category, mode and options are
    /// identical for every engine (FR-022).
    func activate() async throws

    /// Deactivates the session. Only on a real stop — NEVER during a suspension (FR-030):
    /// keeping it active is precisely what allows resuming instead of restarting.
    func deactivate() async

    /// Begins observing interruptions, route changes, configuration changes and media-services
    /// resets. Call before `activate()`.
    func startObserving() async

    /// Stops observing and removes the observers.
    func stopObserving() async

    /// One reactivation attempt. Returns true if the session is now active.
    ///
    /// This is the primitive behind the backup poll (research §R2): its success is the REAL
    /// signal that an interruption ended, without depending on a notification that iOS does not
    /// reliably deliver. It is what covers the unattended-alarm case.
    func attemptReactivation() async -> Bool

    /// Marks the session as suspended so the coordinator starts polling for recovery.
    func noteSuspended(reason: AudioInterruptionReason) async

    /// Marks the session as no longer suspended, stopping the poll.
    func noteResumed() async
}

/// What the coordinator reports upward. Deliberately free of AVFoundation types: the ViewModel
/// lives in Presentation and must not import Data — gate G1.
enum AudioSessionEvent: Sendable, Equatable {

    /// Suspend capture. Do NOT end the session: history is preserved and the stream stays open.
    case interrupted(AudioInterruptionReason)

    /// Resume. Emitted both by the end-of-interruption notification and by a successful poll.
    case resumed

    /// The input node's format changed. The tap must be reinstalled with the NEW format,
    /// never a cached one (research §R4).
    case captureNeedsRebuild(AudioInterruptionReason)

    /// Reactivation kept failing past the ceiling. The only legitimate path from `suspended`
    /// to `stopping`.
    case giveUp(afterMs: Int)
}

// MARK: - Resume policy (research §R2)

/// Declared as `nonisolated` computed properties rather than `static let`. With
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, static stored properties are MainActor-isolated
/// and reading them from an actor is a concurrency violation (gate G5).
enum ResumePolicy {
    /// Backup poll cadence. A compromise between meeting SC-005 (resume within 2 000 ms) and
    /// not burning battery polling.
    nonisolated static var pollIntervalMs: Int { 2_000 }

    /// Total ceiling before giving up and telling the user.
    nonisolated static var giveUpAfterMs: Int { 60_000 }

    /// Budget for rebuilding capture after a route change (SC-008).
    nonisolated static var rebuildBudgetMs: Int { 1_000 }
}

// MARK: - Single source of audio session configuration (FR-022)

/// One place where this lives. It used to be triplicated and inconsistent: two engines used
/// `.default` while the third used `.measurement`, which disables automatic gain control and
/// noise reduction — exactly what feature 005 identified as critical for accented, distant or
/// quiet speech.
enum AudioSessionConfig {
    nonisolated static var categoryName: String { "record" }
    nonisolated static var modeName: String { "default" }   // NEVER .measurement: keeps AGC + NR
    nonisolated static var optionsName: String { "duckOthers" }

    /// Decision Q3: capturing with the screen locked requires the background audio mode in
    /// Info.plist. Accepted consequence, recorded in the spec.
    nonisolated static var requiresBackgroundAudioMode: Bool { true }
}
