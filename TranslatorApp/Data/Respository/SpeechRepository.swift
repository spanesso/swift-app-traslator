//
//  SpeechRepository.swift
//  TranslatorApp
//
//  Adapter between SpeechRepositoryProtocol (use-case surface) and SpeechEngineProtocol.
//  Routes through VADGate and records per-token confidence in QualityMetricsService.

import OSLog

final class SpeechRepository: SpeechRepositoryProtocol {
    private let engine: any SpeechEngineProtocol
    private let vadGate: VADGate
    private let qualityMetrics: QualityMetricsService
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "SpeechRepo")

    init(engine: any SpeechEngineProtocol,
         qualityMetrics: QualityMetricsService,
         vadGate: VADGate = VADGate()) {
        self.engine = engine
        self.qualityMetrics = qualityMetrics
        self.vadGate = vadGate
    }

    func startTranscription() async throws -> AsyncStream<SpeechSegment> {
        logger.info("[SpeechRepo] starting engine=\(self.engine.engineId.rawValue)")
        let raw = try await engine.start(options: SpeechEngineOptions())
        let gated = await vadGate.filter(raw)
        return attachQualityRecording(to: gated)
    }

    func stopTranscription() async {
        logger.info("[SpeechRepo] stopping")
        await engine.stop()
    }

    // MARK: - Quality recording tap

    private func attachQualityRecording(to stream: AsyncStream<SpeechSegment>) -> AsyncStream<SpeechSegment> {
        AsyncStream { continuation in
            Task {
                for await segment in stream {
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
