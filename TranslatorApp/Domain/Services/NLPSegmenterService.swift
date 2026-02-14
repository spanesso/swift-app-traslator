//
//  NLPSegmenterService.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import Foundation
import NaturalLanguage
import OSLog
import CryptoKit
 

final class NLPSegmenterService: NLPSegmenterServiceProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Segmenter")
    
    // /CAMBIO/ Delay optimizado para permitir que el ASR "estabilice" las palabras anteriores
    private let baseStabilityDelay: UInt64 = 1_200_000_000 // 1.2s
    private let qualityMetrics: QualityMetricsService
    
    // /CAMBIO/ Guardamos el texto procesado para comparación de longitud y contenido
    private var lastEmittedFullText: String = ""
    
    init(qualityMetrics: QualityMetricsService) {
        self.qualityMetrics = qualityMetrics
    }
    
    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<String> {
        return AsyncStream { continuation in
            Task {
                let sessionId = UUID().uuidString
                await qualityMetrics.startSession(sessionId: sessionId)
                
                var stabilityTimer: Task<Void, Never>?
                
                for await segment in stream {
                    let currentFullText = segment.text
                    
                    stabilityTimer?.cancel()
                    
                    // /CAMBIO/ Si el texto actual es más corto o igual en longitud al último emitido,
                    // significa que el ASR está corrigiendo o no hay nada nuevo real.
                    if currentFullText.count <= lastEmittedFullText.count {
                        continue
                    }
                    
                    stabilityTimer = Task {
                        try? await Task.sleep(nanoseconds: baseStabilityDelay)
                        guard !Task.isCancelled else { return }
                        
                        await processDifferentialText(currentFullText, to: continuation)
                    }
                }
                continuation.finish()
            }
        }
    }

    private func processDifferentialText(_ newFullText: String, to continuation: AsyncStream<String>.Continuation) async {
        // /CAMBIO/ Lógica de recorte de seguridad.
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
        
        // /CAMBIO/ Solo emitimos si hay una "frase" sustancial (mínimo 5 palabras)
        // para evitar micro-traducciones sin contexto.
        if words.count >= 5 || newFullText.hasSuffix(".") {
            logger.info("✨ [Segmenter] Delta Detected: \(trimmedDelta)")
            lastEmittedFullText = newFullText
            continuation.yield(trimmedDelta)
        }
    }
    
    // /CAMBIO/ Función auxiliar para encontrar realmente qué es lo nuevo
    private func findActualNewContent(old: String, new: String) -> String {
        let oldWords = old.components(separatedBy: .whitespaces)
        let newWords = new.components(separatedBy: .whitespaces)
        
        if newWords.count > oldWords.count {
            return newWords.dropFirst(oldWords.count).joined(separator: " ")
        }
        return ""
    }
}
