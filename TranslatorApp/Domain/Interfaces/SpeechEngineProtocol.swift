//
//  SpeechEngineProtocol.swift
//  TranslatorApp
//
//  Domain-layer contract for any speech-recognition engine.
//  Adapters live in Data/SpeechEngines/. Pure Foundation — no framework-specific imports.

import Foundation

/// A pluggable ASR engine. Multiple consecutive sessions on the same instance are supported.
protocol SpeechEngineProtocol: Sendable {
    var engineId: EngineId { get }
    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment>
    func stop() async
}

struct SpeechEngineOptions: Sendable {
    let locale: String
    let accentHint: AccentGroup?
    let requestsTokenDetail: Bool

    init(locale: String = "en-US",
         accentHint: AccentGroup? = nil,
         requestsTokenDetail: Bool = true) {
        self.locale = locale
        self.accentHint = accentHint
        self.requestsTokenDetail = requestsTokenDetail
    }
}

enum SpeechEngineError: Error, Sendable, Equatable {
    case notAuthorized
    case engineConfigurationFailed
    case modelUnavailable
    case unsupportedLocale
    case unsupportedDevice
}
