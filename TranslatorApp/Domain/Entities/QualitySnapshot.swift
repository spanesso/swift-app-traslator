//
//  QualitySnapshot.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

import Foundation

struct QualitySnapshot {
    let revisionRate: Double // revisiones por minuto
    let avgStabilityDelay: TimeInterval // segundos
    let avgWordsPerSecond: Double
    let avgConfidence: Float
    let avgFragmentation: Double // 0.0 - 1.0
    let totalRevisions: Int
}
