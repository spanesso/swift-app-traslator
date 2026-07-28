//
//  EmptySegmentFilter.swift (CONTRACT) — feature 006-fix-asr-word-loss
//
//  Rename + clarification of the misnamed `VADGate`. This is NOT acoustic/energy VAD:
//  it drops empty/whitespace-only TEXT segments that arrive within a short window of the
//  last non-empty segment, to suppress WhisperKit silence-loop artifacts. Real energy VAD,
//  when needed, comes from WhisperKit's `chunkingStrategy: .vad` (see W2/W6), not from here.
//
//  Placement: TranslatorApp/Data/Audio/EmptySegmentFilter.swift  (was VADGate.swift)
//  Imports: Foundation only.
//

import Foundation

/// Filters empty-text segments out of a segment stream. Applied EXACTLY ONCE in the pipeline
/// (today it is applied twice — inside WhisperKitEngine AND in SpeechRepository — remove one).
protocol EmptySegmentFiltering: Sendable {
    /// Wraps `input`, dropping any segment whose trimmed text is empty when it follows another
    /// segment within `silenceWindow`. Non-empty segments pass through unchanged. Silence that
    /// persists beyond the window passes through so the segmenter's stability timer can flush.
    func filter(_ input: AsyncStream<SpeechSegment>) -> AsyncStream<SpeechSegment>

    /// Coalescing window (default ~500 ms).
    var silenceWindow: Duration { get }
}

// Contract notes:
// - Single application point: pick ONE of { WhisperKitEngine, SpeechRepository }. The repository
//   is the natural home so every engine benefits uniformly; then remove the in-engine call.
// - This filter must never drop a non-empty segment, and must never delay a non-empty segment.
// - Naming: the type is renamed from `VADGate` to end the "it's a VAD" confusion in the codebase.
