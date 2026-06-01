//
//  NLPSegmenterService.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import Foundation
import NaturalLanguage
import OSLog
<<<<<<< HEAD


final class NLPSegmenterService: NLPSegmenterServiceProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Segmenter")

    // Respaldo corto cuando no hay límite gramatical — solo para cláusulas abiertas
    private let stabilityDelay: UInt64 = 700_000_000 // 0.7s
    // Si una cláusula sin terminador supera este número de palabras, forzamos corte por cláusula
    private let longSentenceWordThreshold = 15
    // Mínimo para evitar micro-frases (una palabra aislada no se traduce)
    private let minShortPhraseWords = 2
    // Fallback duro: si el buffer pendiente lleva más de este tiempo sin flush, forzamos emisión
    private let maxPendingInterval: TimeInterval = 6.0
    // Máximo tiempo de retención al parar la grabación (T008) — default: 5.0s
    var maxFlushDelay: TimeInterval = 5.0

    private let qualityMetrics: QualityMetricsService

    // Estado por sesión — reinicializado al comienzo de processStream
    // T005: private(set) exposes committedFullText for tail computation in ViewModel
    private(set) var committedFullText: String = ""
    private var committedWordCount: Int = 0
    private var lastSeenFullText: String = ""
    // Rastreo de inicio del buffer pendiente para el fallback duro por tiempo
    private var pendingStartTime: Date? = nil
    // Contador incremental para identificar cada commit en los logs
    private var commitCounter: Int = 0

    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
    }

=======
import CryptoKit
 

final class NLPSegmenterService: NLPSegmenterServiceProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Segmenter")
    
    //  Delay optimizado para permitir que el ASR "estabilice" las palabras anteriores
    private let baseStabilityDelay: UInt64 = 1_400_000_000 // 1.6s
    private let qualityMetrics: QualityMetricsService
    
    //  Guardamos el texto procesado para comparación de longitud y contenido
    private var lastEmittedFullText: String = ""
    
    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
    }
    
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<String> {
        return AsyncStream { continuation in
            Task {
                let sessionId = UUID().uuidString
                await qualityMetrics.startSession(sessionId: sessionId)
<<<<<<< HEAD

                // Reset por sesión
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

                    // Phase 3 logging
                    if segment.isFinal {
                        self.logger.info("[ASR-FINAL] \(fullText)")
                    } else {
                        self.logger.debug("[ASR-PARTIAL] \(fullText)")
                    }

                    let pending = self.pendingSuffix(of: fullText)
                    guard !pending.isEmpty else { continue }

                    self.logger.debug("[BUFFER-APPEND] pending='\(pending)'")

                    // Track start time for hard timeout
                    if self.pendingStartTime == nil {
                        self.pendingStartTime = Date()
                    }

                    // Fallback duro: el buffer pendiente lleva demasiado tiempo sin flush
                    if let t = self.pendingStartTime, Date().timeIntervalSince(t) > self.maxPendingInterval {
                        let toFlush = self.pendingSuffix(of: fullText)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !toFlush.isEmpty {
                            self.logger.info("[BUFFER-FLUSH reason=timeout] '\(toFlush)'")
                            self.emitIfViable(toFlush, continuation: continuation, tag: "timeout", forceEmit: true)
                        }
                        stabilityTimer?.cancel()
                        continue
                    }

                    // 1. Emitir oraciones completas detectadas por NLTokenizer
                    let sentences = self.splitIntoSentences(pending)
                    if sentences.count >= 2 {
                        for completed in sentences.dropLast() {
                            self.logger.info("[BUFFER-FLUSH reason=sentence] '\(completed)'")
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
                        self.logger.info("[BUFFER-FLUSH reason=\(tag)] '\(tail)'")
                        self.emitIfViable(tail, continuation: continuation, tag: tag)
                        continue
                    }

                    // 2b. Cláusula larga sin terminador → cortar en marcador gramatical
                    if self.wordCount(of: tail) > self.longSentenceWordThreshold,
                       let cut = self.cutAtLastClauseMarker(tail) {
                        let head = cut.head.trimmingCharacters(in: .whitespacesAndNewlines)
                        if self.wordCount(of: head) >= self.minShortPhraseWords {
                            self.logger.info("[BUFFER-FLUSH reason=wordcount] '\(head)'")
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
                        self.logger.info("[BUFFER-FLUSH reason=silence] '\(capturedTail)'")
                        self.emitIfViable(capturedTail, continuation: continuation, tag: "stability")
                    }
                }

                // Stream terminado — flush de lo que quede
                stabilityTimer?.cancel()
                let trailing = self.pendingSuffix(of: self.lastSeenFullText)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !trailing.isEmpty {
                    self.logger.info("[BUFFER-FLUSH reason=flush] '\(trailing)'")
                    self.emitIfViable(trailing, continuation: continuation, tag: "flush", forceEmit: true)
=======
                
                var stabilityTimer: Task<Void, Never>?
                
                for await segment in stream {
                    let currentFullText = segment.text
                    
                    stabilityTimer?.cancel()
                    
                    //  Si el texto actual es más corto o igual en longitud al último emitido,
                    // significa que el ASR está corrigiendo o no hay nada nuevo real.
                    if currentFullText.count <= lastEmittedFullText.count {
                        continue
                    }
                    
                    stabilityTimer = Task {
                        try? await Task.sleep(nanoseconds: baseStabilityDelay)
                        guard !Task.isCancelled else { return }
                        
                        await processDifferentialText(currentFullText, to: continuation)
                    }
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
                }
                continuation.finish()
            }
        }
    }

<<<<<<< HEAD
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
        let id = commitCounter
        logger.info("[COMMIT id=\(id)] words=\(words) tag=\(tag) | \(trimmed)")
        continuation.yield(trimmed)
    }

    private func commit(_ text: String) {
        let words = wordCount(of: text)
        committedWordCount += words
        pendingStartTime = nil  // reset hard timeout on successful commit
        commitCounter += 1
        if committedFullText.isEmpty {
            committedFullText = text
        } else {
            committedFullText += " " + text
        }
    }

    // MARK: - Helpers de texto

    private func pendingSuffix(of fullText: String) -> String {
        let normalized = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let committed = committedFullText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !committed.isEmpty else { return normalized }

        // Intento 1: prefijo exacto (caso normal)
        if normalized.hasPrefix(committed) {
            return String(normalized.dropFirst(committed.count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Intento 2: el ASR revisó texto ya confirmado — saltamos por número de palabras
        // para evitar re-emitir texto comprometido
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
=======
    private func processDifferentialText(_ newFullText: String, to continuation: AsyncStream<String>.Continuation) async {
        //  Lógica de recorte de seguridad.
        // Si el texto nuevo empieza igual que el viejo, solo tomamos lo que sobra.
        var delta = ""
        
        if newFullText.hasPrefix(lastEmittedFullText) {
            delta = String(newFullText.dropFirst(lastEmittedFullText.count))
        } else {
            // Si el ASR cambió algo al inicio, buscamos el punto de divergencia
            // para no repetir párrafos enteros.
            delta = findActualNewContent(old: lastEmittedFullText, new: newFullText)
        }
        
        let trimmedDelta = delta.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmedDelta.components(separatedBy: .whitespaces)
        
        //  Solo emitimos si hay una "frase" sustancial (mínimo 5 palabras)
        // para evitar micro-traducciones sin contexto.
        if words.count >= 5 || newFullText.hasSuffix(".") {
            logger.info("✨ [Segmenter] Delta Detected: \(trimmedDelta)")
            lastEmittedFullText = newFullText
            continuation.yield(trimmedDelta)
        }
    }
    
    //  Función auxiliar para encontrar realmente qué es lo nuevo
    private func findActualNewContent(old: String, new: String) -> String {
        let oldWords = old.components(separatedBy: .whitespaces)
        let newWords = new.components(separatedBy: .whitespaces)
        
        if newWords.count > oldWords.count {
            return newWords.dropFirst(oldWords.count).joined(separator: " ")
        }
        return ""
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
    }
}
