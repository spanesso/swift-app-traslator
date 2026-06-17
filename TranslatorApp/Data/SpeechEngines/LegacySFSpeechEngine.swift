//
//  LegacySFSpeechEngine.swift
//  TranslatorApp
//
//  Thin adapter over ContinuousSpeechListener, preserving its watchdog/restart logic.
//  Used as the Tier 0 fallback on any device that cannot use AppleSpeechAnalyzerEngine.

import Speech
import AVFoundation
import OSLog

actor LegacySFSpeechEngine: SpeechEngineProtocol {
    let engineId: EngineId = .legacyAppleSFSpeech
    private let listener: ContinuousSpeechListener
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "LegacySFSpeech")

    init(listener: ContinuousSpeechListener) {
        self.listener = listener
    }

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        logger.info("[LegacySFSpeech] start locale=\(options.locale)")
        do {
            return try await listener.start()
        } catch let e as SpeechError {
            throw mapError(e)
        }
    }

    func stop() async {
        logger.info("[LegacySFSpeech] stop")
        await listener.stop()
    }

    private func mapError(_ error: SpeechError) -> SpeechEngineError {
        switch error {
        case .notAuthorized: return .notAuthorized
        case .engineConfigurationFailed: return .engineConfigurationFailed
        default: return .engineConfigurationFailed
        }
    }
}
