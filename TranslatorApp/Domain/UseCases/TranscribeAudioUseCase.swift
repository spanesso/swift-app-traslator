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

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UseCase")
    private let qualityMetrics: QualityMetricsService

    // Stored reference so we can cancel the pump explicitly on stop()
    private var pumpTask: Task<Void, Never>?

    init(
        repository: SpeechRepositoryProtocol,
        segmenter: NLPSegmenterServiceProtocol,
        qualityMetrics: QualityMetricsService
    ) {
        self.repository = repository
        self.segmenter = segmenter
        self.qualityMetrics = qualityMetrics
    }

    /// Starts transcription and fans out the single source stream to two independent consumers:
    /// - `raw`: every ASR update (for the live EN display)
    /// - `segmented`: stable phrase chunks (for the translation engine)
    ///
    /// AsyncStream is single-consumer; a pump Task forwards each element to both continuations.
    func executeBoth() async throws -> (raw: AsyncStream<SpeechSegment>, segmented: AsyncStream<String>) {
        logger.info("🎯 [UseCase] Starting dual-output transcription (fan-out)")
        let sourceStream = try await repository.startTranscription()

        let (rawOutput, rawCont) = AsyncStream.makeStream(of: SpeechSegment.self)
        let (segInput, segCont) = AsyncStream.makeStream(of: SpeechSegment.self)

        pumpTask = Task.detached { [logger] in
            for await segment in sourceStream {
                rawCont.yield(segment)
                segCont.yield(segment)
            }
            logger.info("🔚 [UseCase] Source stream ended — finishing fan-out")
            rawCont.finish()
            segCont.finish()
        }

        let segmentedOutput = await segmenter.processStream(segInput)
        return (rawOutput, segmentedOutput)
    }

    func stop() async {
        logger.info("🛑 [UseCase] Stopping transcription")
        pumpTask?.cancel()
        pumpTask = nil
        await repository.stopTranscription()
    }
}
