//
//  RecordingSessionState.swift
//  TranslatorApp
//
//  Lifecycle of a user-visible recording session (008-fix-audio-pipeline-resilience, US5).
//
//  The state this app previously lacked. Without `suspended`, an unattended alarm was
//  indistinguishable from the user deliberately pressing stop: both ended the session, cleared
//  the pipeline and left the user to discover the loss much later.
//
//  | State      | Audio engine | Audio session | Stream  | History   |
//  |------------|--------------|---------------|---------|-----------|
//  | idle       | stopped      | inactive      | closed  | empty     |
//  | active     | running      | active        | open    | growing   |
//  | suspended  | stopped      | ACTIVE        | OPEN    | PRESERVED |
//  | stopping   | stopping     | deactivating  | drained | preserved |
//
//  The `suspended` row is the whole point: keeping the audio session active and the stream open
//  is what makes resuming a resume rather than a restart.
//

import Foundation

enum RecordingSessionState: Sendable, Equatable {
    case idle
    case active
    case suspended(AudioInterruptionReason)
    case stopping

    nonisolated var isRecording: Bool {
        switch self {
        case .active, .suspended: return true
        case .idle, .stopping:    return false
        }
    }

    nonisolated var isSuspended: Bool {
        if case .suspended = self { return true }
        return false
    }

    nonisolated var suspensionReason: AudioInterruptionReason? {
        if case .suspended(let reason) = self { return reason }
        return nil
    }

    /// Legal transitions. The critical prohibition is `suspended → idle`: every exit from
    /// `suspended` goes through `active` (resumed) or `stopping` (explicit give-up after the
    /// retry ceiling). Allowing the direct edge is exactly the defect this feature removes.
    nonisolated func canTransition(to next: RecordingSessionState) -> Bool {
        switch (self, next) {
        case (.idle, .active):            return true
        case (.active, .suspended):       return true
        case (.active, .stopping):        return true
        case (.suspended, .active):       return true   // resumed, by notification or by poll
        case (.suspended, .stopping):     return true   // gave up after the retry ceiling
        case (.suspended, .idle):         return false  // ← never: this is the bug
        case (.stopping, .idle):          return true
        case (let a, let b) where a == b: return true   // idempotent re-entry
        default:                          return false
        }
    }
}
