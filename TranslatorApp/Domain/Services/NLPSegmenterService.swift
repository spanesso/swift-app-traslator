//
//  NLPSegmenterService.swift
//  TranslatorApp
//

import Foundation
import NaturalLanguage
import OSLog

actor NLPSegmenterService: NLPSegmenterServiceProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Segmenter")

    private let stabilityDelay: UInt64           = 700_000_000    // 0.7s — normal
    private let stabilityDelayLowQuality: UInt64 = 1_200_000_000  // 1.2s — low quality ASR
    private let stabilityDelayIncomplete: UInt64 = 2_500_000_000  // 2.5s — grammatically open phrase
    private let longSentenceWordThreshold = 15
    private let minShortPhraseWords = 2
    private let maxPendingInterval: TimeInterval = 6.0

    private let qualityMetrics: QualityMetricsService

    private(set) var committedFullText: String = ""
    private var committedWordCount: Int = 0
    private var lastSeenFullText: String = ""
    private var pendingStartTime: Date?
    private var commitCounter: Int = 0
    // Hypothesis buffer (005-accent-robust-asr): hold without committing
    private var pendingHypothesis: SpeechSegment?

    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
    }

    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                let sessionId = UUID().uuidString
                await qualityMetrics.startSession(sessionId: sessionId)
                committedFullText = ""
                committedWordCount = 0
                lastSeenFullText = ""
                pendingStartTime = nil
                commitCounter = 0
                pendingHypothesis = nil

                var stabilityTimer: Task<Void, Never>?

                for await segment in stream {
                    // Short-utterance guard (T051): suppress ≤1-word segments
                    let wordCount = segment.text.split(separator: " ").count
                    if wordCount < 2 && !segment.isFinal {
                        logger.debug("[SHORT-UTTERANCE suppressed] '\(segment.text)'")
                        continue
                    }

                    // Hypothesis handling (T025): buffer without committing
                    if segment.isHypothesis {
                        pendingHypothesis = segment
                        continue
                    }
                    pendingHypothesis = nil

                    stabilityTimer?.cancel()
                    let fullText = segment.text
                    if fullText == lastSeenFullText { continue }
                    lastSeenFullText = fullText

                    let pending = pendingSuffix(of: fullText)
                    guard !pending.isEmpty else { continue }

                    if pendingStartTime == nil { pendingStartTime = Date() }

                    if let t = pendingStartTime, Date().timeIntervalSince(t) > maxPendingInterval {
                        let toFlush = pendingSuffix(of: fullText).trimmingCharacters(in: .whitespacesAndNewlines)
                        if !toFlush.isEmpty {
                            logger.info("[BUFFER-FLUSH reason=timeout] '\(toFlush)'")
                            emitIfViable(toFlush, continuation: continuation, tag: "timeout", forceEmit: true)
                        }
                        continue
                    }

                    let sentences = splitIntoSentences(pending)
                    if sentences.count >= 2 {
                        for completed in sentences.dropLast() {
                            logger.info("[BUFFER-FLUSH reason=sentence] '\(completed)'")
                            emitIfViable(completed, continuation: continuation, tag: "sentence")
                        }
                    }

                    let tail = pendingSuffix(of: fullText).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tail.isEmpty else { continue }

                    if endsWithTerminator(tail) || segment.isFinal {
                        let tag = segment.isFinal ? "final" : "terminator"
                        logger.info("[BUFFER-FLUSH reason=\(tag)] '\(tail)'")
                        emitIfViable(tail, continuation: continuation, tag: tag)
                        continue
                    }

                    if wordCountOf(tail) > longSentenceWordThreshold,
                       let cut = cutAtLastClauseMarker(tail) {
                        let head = cut.head.trimmingCharacters(in: .whitespacesAndNewlines)
                        if wordCountOf(head) >= minShortPhraseWords {
                            logger.info("[BUFFER-FLUSH reason=wordcount] '\(head)'")
                            emitIfViable(head, continuation: continuation, tag: "clause")
                            continue
                        }
                    }

                    let capturedTail = tail
                    let isLowQuality = await qualityMetrics.isLowQualitySpeech()
                    let isIncomplete = isLikelyIncomplete(tail)
                    let delay: UInt64
                    if isIncomplete {
                        delay = stabilityDelayIncomplete
                        logger.debug("[SEGMENTER] phrase open (grammar), extending timer: '\(tail)'")
                    } else if isLowQuality {
                        delay = stabilityDelayLowQuality
                    } else {
                        delay = stabilityDelay
                    }
                    stabilityTimer = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: delay)
                        guard !Task.isCancelled, let self else { return }
                        let currentTail = await self.pendingSuffix(of: self.lastSeenFullText)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard currentTail == capturedTail else { return }
                        logger.info("[BUFFER-FLUSH reason=silence] '\(capturedTail)'")
                        await self.emitIfViable(capturedTail, continuation: continuation, tag: "stability")
                    }
                }

                stabilityTimer?.cancel()
                let trailing = pendingSuffix(of: lastSeenFullText).trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailing.isEmpty {
                    logger.info("[BUFFER-FLUSH reason=flush] '\(trailing)'")
                    emitIfViable(trailing, continuation: continuation, tag: "flush", forceEmit: true)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Emission

    private func emitIfViable(_ rawText: String, continuation: AsyncStream<String>.Continuation,
                               tag: String, forceEmit: Bool = false) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let words = wordCountOf(trimmed)
        guard forceEmit || words >= minShortPhraseWords else { return }
        commit(trimmed)
        continuation.yield(trimmed)
        logger.info("[COMMIT id=\(self.commitCounter - 1)] words=\(words) tag=\(tag) | \(trimmed)")
    }

    private func commit(_ text: String) {
        committedWordCount += wordCountOf(text)
        pendingStartTime = nil
        commitCounter += 1
        committedFullText = committedFullText.isEmpty ? text : committedFullText + " " + text
    }

    // MARK: - Grammatical completeness

    /// Returns true when the phrase is grammatically open and likely unfinished.
    /// Signals the stability timer to wait longer before committing.
    private func isLikelyIncomplete(_ text: String) -> Bool {
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var lastTag: NLTag?
        var hasVerb = false
        tagger.enumerateTags(in: text.startIndex..<text.endIndex,
                             unit: .word, scheme: .lexicalClass,
                             options: [.omitWhitespace, .omitPunctuation]) { tag, _ in
            if let tag {
                lastTag = tag
                if tag == .verb { hasVerb = true }
            }
            return true
        }
        // Dangling function-word at end = phrase not closed
        let dangling: Set<NLTag> = [.preposition, .conjunction, .determiner, .particle]
        if let last = lastTag, dangling.contains(last) { return true }
        // Multi-word phrase with no verb detected = likely a fragment mid-sentence
        if !hasVerb && wordCountOf(text) > 2 { return true }
        return false
    }

    // MARK: - Text helpers

    private func pendingSuffix(of fullText: String) -> String {
        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = committedFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return normalized }
        if normalized.hasPrefix(committed) {
            return String(normalized.dropFirst(committed.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let words = normalized.split(whereSeparator: \.isWhitespace)
        if words.count <= committedWordCount {
            logger.info("[SEGMENTER] ASR restart detected (words=\(words.count) ≤ committed=\(self.committedWordCount)) — resetting")
            committedFullText = ""; committedWordCount = 0; pendingStartTime = nil
            return normalized
        }
        return words.dropFirst(committedWordCount).joined(separator: " ")
    }

    private func wordCountOf(_ text: String) -> Int { text.split(whereSeparator: \.isWhitespace).count }
    private func endsWithTerminator(_ text: String) -> Bool { ".!?".contains(text.last ?? " ") }

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

    private func cutAtLastClauseMarker(_ text: String) -> (head: String, tail: String)? {
        var bestCut: String.Index?
        for p in [",", ";", ":", "—"] {
            if let r = text.range(of: p, options: .backwards) {
                if bestCut == nil || r.upperBound > bestCut! { bestCut = r.upperBound }
            }
        }
        for conn in [" and ", " but ", " so ", " because ", " however ", " yet ", " although "] {
            if let r = text.range(of: conn, options: .backwards) {
                if bestCut == nil || r.lowerBound > bestCut! { bestCut = r.lowerBound }
            }
        }
        guard let cut = bestCut else { return nil }
        return (String(text[..<cut]), String(text[cut...]))
    }
}
