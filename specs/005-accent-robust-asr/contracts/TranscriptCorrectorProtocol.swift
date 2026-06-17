//
//  TranscriptCorrectorProtocol.swift
//  TranslatorApp — feature 005-accent-robust-asr
//
//  Domain contract for the post-correction stage that takes a noisy ASR segment
//  and returns a cleaner one — under hard anti-hallucination guarantees.
//

import Foundation

/// Post-correction over a single `SpeechSegment`.
///
/// Implementations MUST satisfy four invariants (the test suite verifies all four):
///   1. The output contains no named entity absent from the input.
///   2. The output contains no numeral absent from the input.
///   3. Tokens in the input with `confidence >= lockThreshold` appear unchanged in the output.
///   4. The output never INTRODUCES a higher confidence than the input. Aggregate confidence
///      is bounded above by the input's aggregate.
///
/// The concrete `FoundationModelsCorrector` lives in `Domain/Services/`.
protocol TranscriptCorrectorProtocol: Sendable {
    /// Returns the corrected segment.
    ///
    /// - Parameter segment: the noisy input segment (must have `isFinal == true`).
    /// - Parameter lockThreshold: tokens with confidence ≥ this value are locked and may not be edited.
    /// - Returns: a `CorrectionResult` containing either an accepted correction or the original
    ///   segment (when the candidate edit failed any of the four invariants).
    func correct(segment: SpeechSegment,
                 lockThreshold: Float) async -> CorrectionResult

    /// `true` when the underlying model is available on the current device.
    /// (E.g., Apple Foundation Models requires A17 Pro+.)
    var isAvailable: Bool { get async }
}

/// Outcome of a correction pass — preserves audit trail for the harness.
struct CorrectionResult: Sendable {
    let segment: SpeechSegment             // the segment to emit downstream
    let action: CorrectionAction
    let rejectedReason: CorrectionRejection?

    var wasEdited: Bool {
        if case .accepted = action { return true }
        return false
    }
}

enum CorrectionAction: Sendable, Equatable {
    case skipped(reason: SkipReason)       // didn't even invoke the model
    case accepted                          // model proposed an edit and it passed all guards
    case rejected                          // model proposed an edit; a guard rejected it
}

enum SkipReason: String, Sendable {
    case deviceUnsupported                 // no A17 Pro
    case allTokensHighConfidence           // every token >= lockThreshold
    case latencyBudgetExceeded             // caller-defined gate
}

enum CorrectionRejection: String, Sendable {
    case introducedNamedEntity
    case introducedNumeral
    case modifiedLockedToken
    case raisedConfidenceAboveSource
}
