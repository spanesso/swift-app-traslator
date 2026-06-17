//
//  TranscribeAudioUseCase.swift
//  TranslatorApp
//

import Foundation
import OSLog

final class TranscribeAudioUseCase {
    private let repository: SpeechRepositoryProtocol
    private let segmenter: NLPSegmenterServiceProtocol
    private let qualityMetrics: QualityMetricsService
    private let correctorService: TranscriptCorrectorService

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UseCase")
    private var pumpTask: Task<Void, Never>?
    // Loop detection (T047): ring buffer of last 5 final segments
    private var recentFinalSegments: [SpeechSegment] = []

    init(repository: SpeechRepositoryProtocol,
         segmenter: NLPSegmenterServiceProtocol,
         qualityMetrics: QualityMetricsService,
         correctorService: TranscriptCorrectorService) {
        self.repository = repository
        self.segmenter = segmenter
        self.qualityMetrics = qualityMetrics
        self.correctorService = correctorService
    }

    /// Starts transcription and fans out to two consumers:
    /// - `raw`: every ASR update (EN live display + hypothesis)
    /// - `segmented`: stable, corrected phrase chunks (translation engine)
    func executeBoth() async throws -> (raw: AsyncStream<SpeechSegment>, segmented: AsyncStream<String>) {
        logger.info("🎯 [UseCase] Starting dual-output transcription (fan-out)")
        let sourceStream = try await repository.startTranscription()
        recentFinalSegments = []

        let (rawOutput, rawCont) = AsyncStream.makeStream(of: SpeechSegment.self)
        let (segInput, segCont) = AsyncStream.makeStream(of: SpeechSegment.self)

        pumpTask = Task.detached { [weak self, logger] in
            guard let self else { return }
            for await segment in sourceStream {
                rawCont.yield(segment)

                // Hypothesis segments (WhisperKit mid-window): skip segmenter entirely.
                // They are already displayed via the raw stream in the EN pane.
                guard !segment.isHypothesis else { continue }

                if segment.isFinal {
                    // Corrector runs only on final segments (too slow for partials).
                    let corrected = await self.correctorService.process(segment)
                    if await self.isLooping(corrected) {
                        logger.warning("[LOOP-DETECT] dropped: '\(corrected.text)'")
                        continue
                    }
                    segCont.yield(corrected)
                } else {
                    // Partial segments go to the segmenter unchanged so the
                    // NLPSegmenterService 3-tier cascade can track cumulative text.
                    segCont.yield(segment)
                }
            }
            logger.info("🔚 [UseCase] Source stream ended")
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

    // MARK: - Loop detection (SC-008 / T047)

    private func isLooping(_ segment: SpeechSegment) -> Bool {
        recentFinalSegments.append(segment)
        if recentFinalSegments.count > 5 { recentFinalSegments.removeFirst() }
        guard recentFinalSegments.count >= 3 else { return false }

        let words = segment.text.lowercased().split(separator: " ").map(String.init)
        guard words.count >= 3 else { return false }

        let trigrams = zip(zip(words, words.dropFirst()), words.dropFirst().dropFirst())
            .map { "\($0.0.0) \($0.0.1) \($0.1)" }

        let allTexts = recentFinalSegments.map { $0.text.lowercased() }
        for trigram in trigrams {
            let occurrences = allTexts.filter { $0.contains(trigram) }.count
            if occurrences >= 3 { return true }
        }
        return false
    }
}
