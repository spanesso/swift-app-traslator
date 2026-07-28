//
//  SaveConversationUseCase.swift
//  TranslatorApp
//

import Foundation
import OSLog

enum ConversationError: Error, LocalizedError {
    case emptyTranscript
    /// The two language blocks do not have the same number of lines, so the positional
    /// correspondence the export relies on would be broken (008 FR-033 / SC-020).
    case misalignedBlocks(englishLines: Int, spanishLines: Int)

    var errorDescription: String? {
        switch self {
        case .emptyTranscript:
            return "Nothing to save — no speech was captured."
        case .misalignedBlocks(let en, let es):
            return "Transcript and translation are out of step (\(en) vs \(es) lines)."
        }
    }
}

final class SaveConversationUseCase {
    private let repository: ConversationRepositoryProtocol
    private let telemetry: any PipelineTelemetryProtocol
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UseCase")

    init(repository: ConversationRepositoryProtocol, telemetry: any PipelineTelemetryProtocol) {
        self.repository = repository
        self.telemetry = telemetry
    }

    func execute(englishText: String, spanishText: String) async throws {
        let trimmedEN = englishText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedES = spanishText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedEN.isEmpty else { throw ConversationError.emptyTranscript }

        // The invariant that makes the export auditable. Previously only the English side was
        // validated and the Spanish side was persisted however it came — including empty,
        // silently. A mismatch here means a fragment was dropped rather than marked, which is
        // the failure mode this feature exists to remove, so it fails loudly.
        let englishLines = ConversationTextFormatter.lineCount(trimmedEN)
        let spanishLines = ConversationTextFormatter.lineCount(trimmedES)
        guard englishLines == spanishLines else {
            telemetry.exportAlignment(TelemetrySessionId.new(),
                                      enLines: englishLines,
                                      esLines: spanishLines,
                                      unavailable: 0)
            logger.error("[UseCase] refused to save misaligned blocks EN=\(englishLines) ES=\(spanishLines)")
            throw ConversationError.misalignedBlocks(englishLines: englishLines,
                                                     spanishLines: spanishLines)
        }

        let entity = ConversationEntity(id: UUID(),
                                        englishText: trimmedEN,
                                        spanishText: trimmedES,
                                        savedAt: Date())
        logger.info("📝 [UseCase] Saving conversation (\(englishLines) aligned lines)")
        try await repository.save(entity)
        logger.info("✅ [UseCase] Conversation saved successfully id=\(entity.id)")
    }
}
