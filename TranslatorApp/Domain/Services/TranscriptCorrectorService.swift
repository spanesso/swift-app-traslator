//
//  TranscriptCorrectorService.swift
//  TranslatorApp
//
//  Domain-layer gate that decides whether to invoke the corrector.
//  Skips correction on pre-A17 devices or when all tokens are already high-confidence.

import Foundation
import OSLog

actor TranscriptCorrectorService {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "CorrectorService")
    private let corrector: (any TranscriptCorrectorProtocol)?
    private let lockThreshold: Float
    private var invocations = 0
    private var accepted = 0
    private var rejected = 0

    init(corrector: (any TranscriptCorrectorProtocol)?, lockThreshold: Float = 0.85) {
        self.corrector = corrector
        self.lockThreshold = lockThreshold
    }

    /// Applies the corrector gate from data-model.md §4.2.
    /// Returns the (possibly corrected) segment, always safe to emit downstream.
    func process(_ segment: SpeechSegment) async -> SpeechSegment {
        guard segment.isFinal, let corrector, !segment.tokens.isEmpty else {
            return segment
        }
        guard DeviceCapabilities.supportsA17Pro else {
            return segment
        }
        let minConf = segment.tokens.map(\.confidence).min() ?? 1.0
        guard minConf < lockThreshold else {
            logger.debug("[CorrectorService] skip high-confidence segment conf=\(String(format:"%.2f",minConf))")
            return segment
        }

        invocations += 1
        let result = await corrector.correct(segment: segment, lockThreshold: lockThreshold)
        switch result.action {
        case .accepted:
            accepted += 1
            logger.info("[CorrectorService] accepted edit #\(self.accepted)")
        case .rejected:
            rejected += 1
            logger.warning("[CorrectorService] rejected edit #\(self.rejected): \(result.rejectedReason?.rawValue ?? "unknown")")
        case .skipped(let reason):
            logger.debug("[CorrectorService] skipped: \(reason.rawValue)")
        }
        return result.segment
    }

    var stats: (invocations: Int, accepted: Int, rejected: Int) {
        (invocations, accepted, rejected)
    }
}
