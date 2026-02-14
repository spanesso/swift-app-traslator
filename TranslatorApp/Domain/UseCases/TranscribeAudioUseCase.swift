//
//  TranscribeAudioUseCase.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import Foundation
import OSLog

final class TranscribeAudioUseCase {
    private let repository: SpeechRepositoryProtocol
    private let segmenter: NLPSegmenterServiceProtocol
    
    // /CAMBIO/ Logger estructurado
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UseCase")
    
    // /CAMBIO/ Inyección de métricas
    private let qualityMetrics: QualityMetricsService
    
    init(
        repository: SpeechRepositoryProtocol,
        segmenter: NLPSegmenterServiceProtocol,
        qualityMetrics: QualityMetricsService
    ) {
        self.repository = repository
        self.segmenter = segmenter
        self.qualityMetrics = qualityMetrics
    }
    
    func executeRaw() async throws -> AsyncStream<SpeechSegment> {
        logger.info("🎯 [UseCase] Starting raw transcription")
        return try await repository.startTranscription()
    }
    
    func executeSegmented(from stream: AsyncStream<SpeechSegment>) -> AsyncStream<String> {
        logger.info("🎯 [UseCase] Starting segmented transcription")
        return segmenter.processStream(stream)
    }
    
    func stop() async {
        logger.info("🛑 [UseCase] Stopping transcription")
        await repository.stopTranscription()
    }
}
