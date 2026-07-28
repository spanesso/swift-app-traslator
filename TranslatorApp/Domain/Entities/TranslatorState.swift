//
//  TranslatorState.swift
//  TranslatorApp
//

enum TranslatorState: Sendable, Equatable {
    case idle
    case downloadingModel       // Apple Translation pack download
    case inFlight               // translation request in flight
    case error
    case permissionDenied
    case modelUnavailable
    // Added in 005-accent-robust-asr
    case downloadingASRModel(progress: Double)  // WhisperKit model download
    case correcting                             // Foundation Models corrector pass in flight
    /// Added in 008: capture is paused by a system sound, a call, or a device change, and will
    /// resume by itself. Distinct from `.error` and emphatically distinct from
    /// `.permissionDenied`, which is what every interruption used to be reported as.
    case suspendedByAudioInterruption(AudioInterruptionReason)

    static func == (lhs: TranslatorState, rhs: TranslatorState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.downloadingModel, .downloadingModel),
             (.inFlight, .inFlight),
             (.error, .error),
             (.permissionDenied, .permissionDenied),
             (.modelUnavailable, .modelUnavailable),
             (.correcting, .correcting):
            return true
        case (.downloadingASRModel(let a), .downloadingASRModel(let b)):
            return a == b
        case (.suspendedByAudioInterruption(let a), .suspendedByAudioInterruption(let b)):
            return a == b
        default:
            return false
        }
    }
}
