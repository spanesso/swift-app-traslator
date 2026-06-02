//
//  NLPSegmenterService.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import Foundation
import NaturalLanguage
import OSLog

actor NLPSegmenterService: NLPSegmenterServiceProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Segmenter")

    // 0.7 s — short silence before flush under normal ASR quality
    private let stabilityDelay: UInt64 = 700_000_000
    // 1.2 s — longer silence when ASR quality is low
    private let stabilityDelayLowQuality: UInt64 = 1_200_000_000
    // Force a clause-marker cut when the pending tail exceeds this many words
    private let longSentenceWordThreshold = 15
    // Minimum phrase length to emit (prevents micro-translations)
    private let minShortPhraseWords = 2
    // Hard timeout — flush pending buffer if it has been waiting this long
    private let maxPendingInterval: TimeInterval = 6.0

    private let qualityMetrics: QualityMetricsService

    // Per-session state — reset at the start of every processStream call
    private(set) var committedFullText: String = ""
    private var committedWordCount: Int = 0
    private var lastSeenFullText: String = ""
    private var pendingStartTime: Date?
    private var commitCounter: Int = 0

    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
    }

    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<String> {
        return AsyncStream { continuation in
            Task {
                let sessionId = UUID().uuidString
                await qualityMetrics.startSession(sessionId: sessionId)

                // Reset per-session state
                self.committedFullText = ""
                self.committedWordCount = 0
                self.lastSeenFullText = ""
                self.pendingStartTime = nil
                self.commitCounter = 0

                var stabilityTimer: Task<Void, Never>?

                for await segment in stream {
                    stabilityTimer?.cancel()

                    let fullText = segment.text
                    if fullText == self.lastSeenFullText { continue }
                    self.lastSeenFullText = fullText

                    if segment.isFinal {
                        self.logger.info("[ASR-FINAL] \(fullText)")
                    } else {
                        self.logger.debug("[ASR-PARTIAL] \(fullText)")
                    }

                    let pending = self.pendingSuffix(of: fullText)
                    guard !pending.isEmpty else { continue }

                    self.logger.debug("[BUFFER-APPEND] pending='\(pending)'")

                    if self.pendingStartTime == nil {
                        self.pendingStartTime = Date()
                    }

                    // Hard timeout — flush if buffer has been waiting too long
                    if let t = self.pendingStartTime, Date().timeIntervalSince(t) > self.maxPendingInterval {
                        let toFlush = self.pendingSuffix(of: fullText)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !toFlush.isEmpty {
                            self.logger.info("[BUFFER-FLUSH reason=timeout] '\(toFlush)'")
                            self.emitIfViable(toFlush, continuation: continuation, tag: "timeout", forceEmit: true)
                        }
                        continue
                    }

                    // 1. Emit completed sentences detected by NLTokenizer
                    let sentences = self.splitIntoSentences(pending)
                    if sentences.count >= 2 {
                        for completed in sentences.dropLast() {
                            self.logger.info("[BUFFER-FLUSH reason=sentence] '\(completed)'")
                            self.emitIfViable(completed, continuation: continuation, tag: "sentence")
                        }
                    }

                    let tail = self.pendingSuffix(of: fullText)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tail.isEmpty else { continue }

                    // 2a. Sentence terminator (.!?) or isFinal → emit immediately
                    if self.endsWithTerminator(tail) || segment.isFinal {
                        let tag = segment.isFinal ? "final" : "terminator"
                        self.logger.info("[BUFFER-FLUSH reason=\(tag)] '\(tail)'")
                        self.emitIfViable(tail, continuation: continuation, tag: tag)
                        continue
                    }

                    // 2b. Long clause without terminator → cut at last clause marker
                    if self.wordCount(of: tail) > self.longSentenceWordThreshold,
                       let cut = self.cutAtLastClauseMarker(tail) {
                        let head = cut.head.trimmingCharacters(in: .whitespacesAndNewlines)
                        if self.wordCount(of: head) >= self.minShortPhraseWords {
                            self.logger.info("[BUFFER-FLUSH reason=wordcount] '\(head)'")
                            self.emitIfViable(head, continuation: continuation, tag: "clause")
                            continue
                        }
                    }

                    // 2c. Silence timer — adapt delay based on ASR quality
                    let capturedTail = tail
                    let isLowQuality = await qualityMetrics.isLowQualitySpeech()
                    let delay = isLowQuality ? self.stabilityDelayLowQuality : self.stabilityDelay

                    stabilityTimer = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled, let self = self else { return }
                        let currentTail = await self.pendingSuffix(of: self.lastSeenFullText)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard currentTail == capturedTail else { return }
                        self.logger.info("[BUFFER-FLUSH reason=silence] '\(capturedTail)'")
                        await self.emitIfViable(capturedTail, continuation: continuation, tag: "stability")
                    }
                }

                // Stream ended — flush any remaining buffer
                stabilityTimer?.cancel()
                let trailing = self.pendingSuffix(of: self.lastSeenFullText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailing.isEmpty {
                    self.logger.info("[BUFFER-FLUSH reason=flush] '\(trailing)'")
                    self.emitIfViable(trailing, continuation: continuation, tag: "flush", forceEmit: true)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Emission

    private func emitIfViable(_ rawText: String,
                               continuation: AsyncStream<String>.Continuation,
                               tag: String,
                               forceEmit: Bool = false) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let words = self.wordCount(of: trimmed)
        guard forceEmit || words >= self.minShortPhraseWords else {
            logger.debug("[SUPPRESS reason=min-words] '\(trimmed)'")
            return
        }
        commit(trimmed)
        let id = commitCounter
        logger.info("[COMMIT id=\(id)] words=\(words) tag=\(tag) | \(trimmed)")
        continuation.yield(trimmed)
    }

    private func commit(_ text: String) {
        let words = wordCount(of: text)
        committedWordCount += words
        pendingStartTime = nil
        commitCounter += 1
        committedFullText = committedFullText.isEmpty ? text : committedFullText + " " + text
    }

    // MARK: - Text helpers

    private func pendingSuffix(of fullText: String) -> String {
        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = committedFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return normalized }

        if normalized.hasPrefix(committed) {
            return String(normalized.dropFirst(committed.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // ASR revised committed text — skip by word count to avoid re-emitting
        let words = normalized.split(whereSeparator: \.isWhitespace)
        guard words.count > committedWordCount else { return "" }
        return words.dropFirst(committedWordCount).joined(separator: " ")
    }

    private func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private func endsWithTerminator(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ".!?".contains(last)
    }

    private func splitIntoSentences(_ text: String) -> [String] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var result: [String] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let piece = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            return true
        }
        return result
    }

    /// Cuts at the last grammatical clause marker.
    /// Priority: punctuation (`,;:—`) > discourse connectors (`and`, `but`, `so`, etc.).
    private func cutAtLastClauseMarker(_ text: String) -> (head: String, tail: String)? {
        var bestCutPosition: String.Index?

        for p in [",", ";", ":", "—"] {
            if let r = text.range(of: p, options: .backwards) {
                let pos = r.upperBound
                if bestCutPosition == nil || pos > bestCutPosition! { bestCutPosition = pos }
            }
        }

        let connectors = [" and ", " but ", " so ", " because ", " however ", " yet ", " although "]
        for conn in connectors {
            if let r = text.range(of: conn, options: .backwards) {
                let pos = r.lowerBound
                if bestCutPosition == nil || pos > bestCutPosition! { bestCutPosition = pos }
            }
        }

        guard let cut = bestCutPosition else { return nil }
        let head = String(text[text.startIndex..<cut])
        let tail = String(text[cut...])
        return (head, tail)
    }
}
