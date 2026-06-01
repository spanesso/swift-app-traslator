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
    
    //  Logger estructurado
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UseCase")
    
    //  Inyección de métricas
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
<<<<<<< HEAD

    /// Produce ambos streams a partir de una sola invocación al repository.
    /// Un pump Task central fan-out cada segmento a dos continuations independientes
    /// (AsyncStream es single-consumer; iterar el mismo stream en dos for-await
    /// reparte los segmentos en orden impredecible).
    func executeBoth() async throws -> (raw: AsyncStream<SpeechSegment>, segmented: AsyncStream<String>) {
        logger.info("🎯 [UseCase] Starting dual-output transcription (fan-out)")
        let sourceStream = try await repository.startTranscription()

        let (rawOutput, rawCont) = AsyncStream.makeStream(of: SpeechSegment.self)
        let (segInput, segCont) = AsyncStream.makeStream(of: SpeechSegment.self)

        Task.detached { [logger] in
            for await segment in sourceStream {
                rawCont.yield(segment)
                segCont.yield(segment)
            }
            logger.info("🔚 [UseCase] Source stream ended — finishing fan-out")
            rawCont.finish()
            segCont.finish()
        }

        let segmentedOutput = segmenter.processStream(segInput)
        return (rawOutput, segmentedOutput)
    }

=======
    
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
    func stop() async {
        logger.info("🛑 [UseCase] Stopping transcription")
        await repository.stopTranscription()
    }
}
