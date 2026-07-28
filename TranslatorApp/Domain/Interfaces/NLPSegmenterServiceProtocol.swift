//
//  NLPSegmenterServiceProtocol.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

/// A committed phrase emitted by the segmenter, carrying the confidence of the ASR segment it
/// was derived from (006-fix-asr-word-loss). Threading confidence here — instead of reading a
/// mutable "latest segment" in the ViewModel — binds the confidence indicator to the phrase it
/// actually represents (SC-006).
struct SegmentedPhrase: Sendable {
    let text: String
    let confidence: Float

    nonisolated init(text: String, confidence: Float = 1.0) {
        self.text = text
        self.confidence = confidence
    }
}

protocol NLPSegmenterServiceProtocol {
    // processStream is async because NLPSegmenterService is an actor
    func processStream(_ stream: AsyncStream<SpeechSegment>) async -> AsyncStream<SegmentedPhrase>
}
