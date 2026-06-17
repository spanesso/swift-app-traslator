//
//  SpeechSegment.swift
//  TranslatorApp
//

// nonisolated init allows construction from any actor (e.g., ContinuousSpeechListener)
// without SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor making this @MainActor-only.
struct SpeechSegment: Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Float
    // Added in 005-accent-robust-asr — defaulted so all existing call sites compile unchanged.
    let tokens: [TranscriptToken]
    let source: EngineId
    let isHypothesis: Bool

    nonisolated init(
        text: String,
        isFinal: Bool,
        confidence: Float = 1.0,
        tokens: [TranscriptToken] = [],
        source: EngineId = .legacyAppleSFSpeech,
        isHypothesis: Bool = false
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.tokens = tokens
        self.source = source
        self.isHypothesis = isHypothesis
    }
}
