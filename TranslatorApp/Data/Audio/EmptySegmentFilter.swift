//
//  EmptySegmentFilter.swift
//  TranslatorApp
//
//  Renamed from `VADGate` (feature 006-fix-asr-word-loss): this is NOT acoustic/energy VAD.
//  It drops empty / whitespace-only TEXT segments that arrive within a short window of the
//  last non-empty segment, to suppress WhisperKit silence-loop artifacts. Real energy VAD,
//  when needed, comes from WhisperKit's `chunkingStrategy: .vad`, not from here.
//
//  Applied EXACTLY ONCE, in `SpeechRepository`, so every engine benefits uniformly.

import Foundation
import OSLog

actor EmptySegmentFilter {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "EmptySegmentFilter")
    // Consecutive empty segments within this window are suppressed.
    private let silenceWindowMs = 500
    /// 008 §R3: `ContinuousClock` rather than `DispatchTime.uptimeNanoseconds`, which stops
    /// while the device sleeps. Under decision Q3 — capturing with the screen locked — that
    /// would make this window measure less time than actually passed, exactly in the scenario
    /// Q3 introduces.
    private var lastNonEmptyYield: ContinuousClock.Instant?

    func filter(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<SpeechSegment> {
        AsyncStream { continuation in
            Task {
                for await segment in stream {
                    let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)

                    if trimmed.isEmpty {
                        if let last = self.lastNonEmptyYield,
                           MonotonicClock.msSince(last) < self.silenceWindowMs {
                            continue
                        }
                        // Pass through silence that persists beyond the window — the segmenter
                        // uses silence to flush its stability timer.
                    } else {
                        self.lastNonEmptyYield = MonotonicClock.now()
                    }

                    continuation.yield(segment)
                }
                continuation.finish()
            }
        }
    }
}
