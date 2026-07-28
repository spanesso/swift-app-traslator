//
//  SpeechRepository.swift
//  TranslatorApp
//
//  Adapter between SpeechRepositoryProtocol (use-case surface) and SpeechEngineProtocol.
//  Routes through EmptySegmentFilter (applied here ONCE for every engine) and records the
//  quality signals the segmenter's adaptive timing depends on.
//

import OSLog

final class SpeechRepository: SpeechRepositoryProtocol {
    private let engine: any SpeechEngineProtocol
    private let emptySegmentFilter: EmptySegmentFilter
    private let qualityMetrics: QualityMetricsService
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "SpeechRepo")

    init(engine: any SpeechEngineProtocol,
         qualityMetrics: QualityMetricsService,
         emptySegmentFilter: EmptySegmentFilter = EmptySegmentFilter()) {
        self.engine = engine
        self.qualityMetrics = qualityMetrics
        self.emptySegmentFilter = emptySegmentFilter
    }

    func startTranscription() async throws -> AsyncStream<SpeechSegment> {
        logger.info("[SpeechRepo] starting engine=\(self.engine.engineId.rawValue, privacy: .public)")
        let raw = try await engine.start(options: SpeechEngineOptions())
        let gated = await emptySegmentFilter.filter(raw)
        return attachQualityRecording(to: gated)
    }

    func stopTranscription() async {
        logger.info("[SpeechRepo] stopping")
        await engine.stop()
    }

    // MARK: - Quality recording tap

    /// Records quality signals for every segment that flows through.
    ///
    /// 008: this moved here from the speech listener. Keeping it in the engine meant threading
    /// a session id that never matched the one the metrics service was tracking, so every
    /// sample was discarded. Here the recorder sits on the stream itself and needs no id.
    private func attachQualityRecording(to stream: AsyncStream<SpeechSegment>) -> AsyncStream<SpeechSegment> {
        AsyncStream { continuation in
            Task { [qualityMetrics] in
                for await segment in stream {
                    await qualityMetrics.recordSegmentObservation(text: segment.text,
                                                                  isFinal: segment.isFinal,
                                                                  confidence: segment.confidence)
                    if segment.isFinal && !segment.tokens.isEmpty {
                        await qualityMetrics.recordTokenConfidences(segment.tokens)
                    }
                    continuation.yield(segment)
                }
                continuation.finish()
            }
        }
    }
}
