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

    /// Which recognition session produced this segment (008-fix-audio-pipeline-resilience, US2).
    ///
    /// Incremented on every internal rotation. Consumers that track cumulative text — the
    /// segmenter and the live-tail reconciler — use a change in this value to know the
    /// recogniser restarted its transcript from zero, so their committed baseline is no longer
    /// comparable.
    ///
    /// Travelling ON the segment rather than through a side channel is deliberate: a separate
    /// signal could arrive before or after the first segment of the new generation, and the
    /// reconciler would reset at the wrong moment.
    let sessionGeneration: Int

    nonisolated init(
        text: String,
        isFinal: Bool,
        confidence: Float = 1.0,
        tokens: [TranscriptToken] = [],
        source: EngineId = .legacyAppleSFSpeech,
        isHypothesis: Bool = false,
        sessionGeneration: Int = 0
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.tokens = tokens
        self.source = source
        self.isHypothesis = isHypothesis
        self.sessionGeneration = sessionGeneration
    }
}
