//
//  SpeechSegment.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

// nonisolated init allows construction from any actor (e.g., ContinuousSpeechListener)
// without SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor making this @MainActor-only.
struct SpeechSegment: Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Float

    nonisolated init(text: String, isFinal: Bool, confidence: Float = 1.0) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}
