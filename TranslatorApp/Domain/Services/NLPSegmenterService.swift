//
//  NLPSegmenterService.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import Foundation
import NaturalLanguage
import OSLog


final class NLPSegmenterService: NLPSegmenterServiceProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Segmenter")

    // Respaldo corto cuando no hay límite gramatical — solo para cláusulas abiertas
    private let stabilityDelay: UInt64 = 700_000_000 // 0.7s
    // Si una cláusula sin terminador supera este número de palabras, forzamos corte por cláusula
    private let longSentenceWordThreshold = 15
    // Mínimo para evitar micro-frases (una palabra aislada no se traduce)
    private let minShortPhraseWords = 2
    // Máximo tiempo de retención al parar la grabación (T008) — default: 5.0s
    var maxFlushDelay: TimeInterval = 5.0

    private let qualityMetrics: QualityMetricsService

    // Estado por sesión — reinicializado al comienzo de processStream
    // T005: private(set) exposes committedFullText for tail computation in ViewModel
    private(set) var committedFullText: String = ""
    private var lastSeenFullText: String = ""

    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
    }

    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<String> {
        return AsyncStream { continuation in
            Task {
                let sessionId = UUID().uuidString
                await qualityMetrics.startSession(sessionId: sessionId)

                // Reset por sesión
                self.committedFullText = ""
                self.lastSeenFullText = ""

                var stabilityTimer: Task<Void, Never>?

                for await segment in stream {
                    stabilityTimer?.cancel()

                    let fullText = segment.text
                    if fullText == self.lastSeenFullText { continue }
                    self.lastSeenFullText = fullText

                    let pending = self.pendingSuffix(of: fullText)
                    guard !pending.isEmpty else { continue }

                    // 1. Emitir oraciones completas detectadas por NLTokenizer
                    let sentences = self.splitIntoSentences(pending)
                    if sentences.count >= 2 {
                        for completed in sentences.dropLast() {
                            self.emitIfViable(completed, continuation: continuation, tag: "sentence")
                        }
                    }

                    // Recalcular lo pendiente tras las emisiones anteriores
                    let tail = self.pendingSuffix(of: fullText)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !tail.isEmpty else { continue }

                    // 2a. Terminador de oración (.!?) o isFinal del ASR → emitir ya
                    if self.endsWithTerminator(tail) || segment.isFinal {
                        let tag = segment.isFinal ? "final" : "terminator"
                        self.emitIfViable(tail, continuation: continuation, tag: tag)
                        continue
                    }

                    // 2b. Cláusula larga sin terminador → cortar en marcador gramatical
                    if self.wordCount(of: tail) > self.longSentenceWordThreshold,
                       let cut = self.cutAtLastClauseMarker(tail) {
                        let head = cut.head.trimmingCharacters(in: .whitespacesAndNewlines)
                        if self.wordCount(of: head) >= self.minShortPhraseWords {
                            self.emitIfViable(head, continuation: continuation, tag: "clause")
                            continue
                        }
                    }

                    // 2c. Respaldo por silencio — timer corto
                    let capturedTail = tail
                    stabilityTimer = Task { [weak self] in
                        try? await Task.sleep(nanoseconds: self?.stabilityDelay ?? 700_000_000)
                        guard !Task.isCancelled, let self = self else { return }
                        let currentTail = self.pendingSuffix(of: self.lastSeenFullText)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        guard currentTail == capturedTail else { return }
                        self.emitIfViable(capturedTail, continuation: continuation, tag: "stability")
                    }
                }

                // Stream terminado — flush de lo que quede
                stabilityTimer?.cancel()
                let trailing = self.pendingSuffix(of: self.lastSeenFullText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailing.isEmpty {
                    self.emitIfViable(trailing, continuation: continuation, tag: "flush", forceEmit: true)
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Emisión

    private func emitIfViable(_ rawText: String,
                              continuation: AsyncStream<String>.Continuation,
                              tag: String,
                              forceEmit: Bool = false) {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let words = self.wordCount(of: trimmed)
        guard forceEmit || words >= self.minShortPhraseWords else { return }

        commit(trimmed)
        logger.info("✨ [Segmenter/\(tag)] words=\(words) | \(trimmed)")
        continuation.yield(trimmed)
    }

    private func commit(_ text: String) {
        if committedFullText.isEmpty {
            committedFullText = text
        } else {
            committedFullText += " " + text
        }
    }

    // MARK: - Helpers de texto

    private func pendingSuffix(of fullText: String) -> String {
        // String-prefix stripping: immune to ASR word-count drift from corrections.
        // Falls back to full text if committed prefix is no longer present (e.g. heavy revision).
        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = committedFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return normalized }
        guard normalized.hasPrefix(committed) else { return normalized }
        return String(normalized.dropFirst(committed.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Corta en el último marcador gramatical disponible.
    /// Prioridad: puntuación (`,;:—`) > conectores discursivos (`and`, `but`, `so`, `because`, `however`).
    /// El `head` se emite como cláusula completa; el `tail` restante espera al siguiente update.
    private func cutAtLastClauseMarker(_ text: String) -> (head: String, tail: String)? {
        var bestCutPosition: String.Index?

        // Puntuación: el marcador se incluye en el head (queda natural para traducir)
        for p in [",", ";", ":", "—"] {
            if let r = text.range(of: p, options: .backwards) {
                let pos = r.upperBound
                if bestCutPosition == nil || pos > bestCutPosition! {
                    bestCutPosition = pos
                }
            }
        }

        // Conectores discursivos: el conector se queda con el tail (encabeza la siguiente frase)
        let connectors = [" and ", " but ", " so ", " because ", " however ", " yet ", " although "]
        for conn in connectors {
            if let r = text.range(of: conn, options: .backwards) {
                let pos = r.lowerBound
                if bestCutPosition == nil || pos > bestCutPosition! {
                    bestCutPosition = pos
                }
            }
        }

        guard let cut = bestCutPosition else { return nil }
        let head = String(text[text.startIndex..<cut])
        let tail = String(text[cut...])
        return (head, tail)
    }
}
