//
//  QualityMetricsService.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

import Foundation
import OSLog

/// Servicio actor-safe para tracking de métricas objetivas de calidad de reconocimiento
actor QualityMetricsService {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Quality")
    
    // Métricas acumuladas
    private var revisionCount: Int = 0
    private var totalRevisions: Int = 0
    private var stabilityDelays: [TimeInterval] = []
    private var wordsPerSecondSamples: [Double] = []
    private var confidenceScores: [Float] = []
    private var fragmentationScores: [Double] = []
    
    private var sessionStartTime: Date?
    private var currentSessionId: String?
    
    // /CAMBIO/ Límite de muestras en memoria
    private let maxSamples = 100
    
    func startSession(sessionId: String) {
        self.currentSessionId = sessionId
        self.sessionStartTime = Date()
        
        // Reset métricas
        revisionCount = 0
        totalRevisions = 0
        stabilityDelays.removeAll()
        wordsPerSecondSamples.removeAll()
        confidenceScores.removeAll()
        fragmentationScores.removeAll()
        
        logger.info("📊 [Quality] Session started: \(sessionId)")
    }
    
    func recordRevision(sessionId: String) {
        guard sessionId == currentSessionId else { return }
        revisionCount += 1
        totalRevisions += 1
        
        logger.debug("🔄 [Quality] Revision #\(self.totalRevisions)")
    }
    
    func recordStabilityDelay(_ delay: TimeInterval, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        
        stabilityDelays.append(delay)
        if stabilityDelays.count > maxSamples {
            stabilityDelays.removeFirst()
        }
    }
    
    func recordWordsPerSecond(_ wps: Double, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        
        wordsPerSecondSamples.append(wps)
        if wordsPerSecondSamples.count > maxSamples {
            wordsPerSecondSamples.removeFirst()
        }
    }
    
    func recordConfidence(_ confidence: Float, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        
        confidenceScores.append(confidence)
        if confidenceScores.count > maxSamples {
            confidenceScores.removeFirst()
        }
    }
    
    func recordFragmentation(_ score: Double, sessionId: String) {
        guard sessionId == currentSessionId else { return }
        
        fragmentationScores.append(score)
        if fragmentationScores.count > maxSamples {
            fragmentationScores.removeFirst()
        }
    }
    
    // /CAMBIO/ Obtener snapshot de métricas
    func getCurrentMetrics() -> QualitySnapshot {
        let avgStability = stabilityDelays.isEmpty ? 0.0 : stabilityDelays.reduce(0, +) / Double(stabilityDelays.count)
        let avgWPS = wordsPerSecondSamples.isEmpty ? 0.0 : wordsPerSecondSamples.reduce(0, +) / Double(wordsPerSecondSamples.count)
        let avgConfidence = confidenceScores.isEmpty ? 0.0 : confidenceScores.reduce(0, +) / Float(confidenceScores.count)
        let avgFragmentation = fragmentationScores.isEmpty ? 0.0 : fragmentationScores.reduce(0, +) / Double(fragmentationScores.count)
        
        // /CAMBIO/ Calcular tasa de revisiones por minuto
        let sessionDuration = sessionStartTime.map { Date().timeIntervalSince($0) } ?? 1.0
        let revisionsPerMinute = Double(totalRevisions) / (sessionDuration / 60.0)
        
        return QualitySnapshot(
            revisionRate: revisionsPerMinute,
            avgStabilityDelay: avgStability,
            avgWordsPerSecond: avgWPS,
            avgConfidence: avgConfidence,
            avgFragmentation: avgFragmentation,
            totalRevisions: totalRevisions
        )
    }
    
    // /CAMBIO/ Determinar si la calidad del habla es baja (para adaptar estrategia)
    func isLowQualitySpeech() -> Bool {
        let metrics = getCurrentMetrics()
        
        // Heurística: calidad baja si...
        // - Alta tasa de revisiones (>10/min)
        // - Baja confianza (<0.6)
        // - Alta fragmentación (>0.15)
        // - Velocidad muy baja (<1.5 wps) o muy alta (>4.0 wps)
        
        let highRevisions = metrics.revisionRate > 10.0
        let lowConfidence = metrics.avgConfidence < 0.6
        let highFragmentation = metrics.avgFragmentation > 0.15
        let abnormalSpeed = metrics.avgWordsPerSecond < 1.5 || metrics.avgWordsPerSecond > 4.0
        
        let isLowQuality = highRevisions || lowConfidence || highFragmentation || abnormalSpeed
        
        if isLowQuality {
            logger.warning("⚠️ [Quality] Low quality detected | revRate=\(String(format: "%.1f", metrics.revisionRate)) conf=\(String(format: "%.2f", metrics.avgConfidence)) frag=\(String(format: "%.2f", metrics.avgFragmentation)) wps=\(String(format: "%.1f", metrics.avgWordsPerSecond))")
        }
        
        return isLowQuality
    }
}
