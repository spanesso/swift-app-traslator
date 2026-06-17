//
//  TranscriptCorrectorProtocol.swift
//  TranslatorApp
//
//  Domain contract for the post-correction stage.
//  Implementations MUST satisfy four invariants (test suite verifies all four):
//    1. Output contains no named entity absent from input.
//    2. Output contains no numeral absent from input.
//    3. Tokens with confidence >= lockThreshold appear unchanged in output.
//    4. Output aggregate confidence is bounded above by input aggregate.

import Foundation

protocol TranscriptCorrectorProtocol: Sendable {
    func correct(segment: SpeechSegment, lockThreshold: Float) async -> CorrectionResult
    var isAvailable: Bool { get async }
}

struct CorrectionResult: Sendable {
    let segment: SpeechSegment
    let action: CorrectionAction
    let rejectedReason: CorrectionRejection?

    var wasEdited: Bool {
        if case .accepted = action { return true }
        return false
    }
}

enum CorrectionAction: Sendable, Equatable {
    case skipped(reason: SkipReason)
    case accepted
    case rejected
}

enum SkipReason: String, Sendable {
    case deviceUnsupported
    case allTokensHighConfidence
    case latencyBudgetExceeded
}

enum CorrectionRejection: String, Sendable {
    case introducedNamedEntity
    case introducedNumeral
    case modifiedLockedToken
    case raisedConfidenceAboveSource
}
