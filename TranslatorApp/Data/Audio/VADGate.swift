//
//  VADGate.swift
//  TranslatorApp
//
//  Voice-activity gate upstream of all ASR engines.
//  Drops empty or silence-only segments to prevent WhisperKit silence-loop artifacts.

import Foundation
import OSLog

actor VADGate {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "VADGate")
    // Consecutive empty segments within this window are suppressed.
    private let silenceWindowNs: UInt64 = 500_000_000 // 500 ms
    private var lastNonEmptyYieldTime: UInt64 = 0

    func filter(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<SpeechSegment> {
        AsyncStream { continuation in
            Task {
                for await segment in stream {
                    let trimmed = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let now = DispatchTime.now().uptimeNanoseconds

                    if trimmed.isEmpty {
                        let elapsed = now - self.lastNonEmptyYieldTime
                        if elapsed < self.silenceWindowNs {
                            self.logger.debug("[VAD] dropped silent segment (elapsed \(elapsed/1_000_000)ms)")
                            continue
                        }
                        // Pass through silence that persists beyond the window — segmenter
                        // uses silence to flush its stability timer.
                    } else {
                        self.lastNonEmptyYieldTime = now
                    }

                    continuation.yield(segment)
                }
                continuation.finish()
            }
        }
    }
}
