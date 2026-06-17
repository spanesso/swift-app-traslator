//
//  SessionQualityRecord.swift
//  TranslatorApp
//
//  SwiftData model for per-session quality metrics.
//  Privacy-safe by design: NO transcript text is stored; only numeric signals.
//  Maximum 50 records retained; oldest is pruned on each insert.

import Foundation
import SwiftData

@Model
final class SessionQualityRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var engineId: String                       // EngineId rawValue
    var accentGroupHint: String?               // AccentGroup rawValue, nil if unknown

    var medianTokenConfidence: Double
    var p10TokenConfidence: Double
    var revisionRatePerMinute: Double
    var avgWordsPerSecond: Double
    var fragmentationScore: Double

    var latencyP50Ms: Double
    var latencyP95Ms: Double

    var hallucinatedEntityCount: Int
    var correctorInvocations: Int
    var correctorAcceptedCorrections: Int

    var conversationId: UUID?

    init(engineId: EngineId,
         accentGroupHint: AccentGroup? = nil,
         conversationId: UUID? = nil) {
        self.id = UUID()
        self.startedAt = Date()
        self.endedAt = nil
        self.engineId = engineId.rawValue
        self.accentGroupHint = accentGroupHint?.rawValue
        self.medianTokenConfidence = 0
        self.p10TokenConfidence = 0
        self.revisionRatePerMinute = 0
        self.avgWordsPerSecond = 0
        self.fragmentationScore = 0
        self.latencyP50Ms = 0
        self.latencyP95Ms = 0
        self.hallucinatedEntityCount = 0
        self.correctorInvocations = 0
        self.correctorAcceptedCorrections = 0
        self.conversationId = conversationId
    }
}
