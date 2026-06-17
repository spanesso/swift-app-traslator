//
//  TranscriptToken.swift
//  TranslatorApp
//

import Foundation

/// A single recognized word with its confidence and optional timing.
/// The unit the UI tints by opacity and the unit the corrector edits or locks.
struct TranscriptToken: Sendable, Hashable {
    let text: String
    let confidence: Float
    let startTime: TimeInterval?
    let endTime: TimeInterval?
    /// True once a corrector pass has locked this token; no downstream pass may edit it.
    let isLocked: Bool

    nonisolated init(
        text: String,
        confidence: Float,
        startTime: TimeInterval? = nil,
        endTime: TimeInterval? = nil,
        isLocked: Bool = false
    ) {
        self.text = text
        self.confidence = confidence
        self.startTime = startTime
        self.endTime = endTime
        self.isLocked = isLocked
    }

    func locking() -> TranscriptToken {
        TranscriptToken(text: text, confidence: confidence,
                        startTime: startTime, endTime: endTime, isLocked: true)
    }
}
