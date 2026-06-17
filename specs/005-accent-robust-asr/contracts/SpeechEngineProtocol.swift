//
//  SpeechEngineProtocol.swift
//  TranslatorApp — feature 005-accent-robust-asr
//
//  Domain-layer contract for any speech-recognition engine the app uses.
//  This protocol abstracts over: iOS 26 SpeechAnalyzer, WhisperKit large-v3-turbo,
//  and the legacy SFSpeechRecognizer fallback. Pure Domain — no framework imports.
//

import Foundation

/// A pluggable speech engine. All adapters live in `Data/SpeechEngines/`.
///
/// Lifecycle: caller invokes `start(options:)` to obtain a stream, drives the stream,
/// then calls `stop()`. Multiple consecutive sessions on the same instance are supported;
/// each `start(...)` returns a fresh stream that finishes when `stop()` is called or the
/// engine ends naturally.
protocol SpeechEngineProtocol: Sendable {
    /// Identifier of this engine. Must match `EngineId` value carried on every emitted segment.
    var engineId: EngineId { get }

    /// Start a transcription session.
    ///
    /// - Returns: an `AsyncStream<SpeechSegment>` that yields partial + final segments
    ///   in chronological order. The stream finishes when:
    ///     - `stop()` is invoked
    ///     - the engine signals an unrecoverable error (the stream finishes; subsequent
    ///       failure detail is surfaced via the throwing `start` call on the next session)
    ///     - the OS revokes microphone permission
    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment>

    /// Stop the in-flight session. Idempotent. Safe to call from any actor.
    func stop() async
}

/// Per-session knobs the engine respects.
struct SpeechEngineOptions: Sendable {
    /// BCP-47 locale tag. v1: always "en-US".
    let locale: String

    /// Hint about the speaker's L1, when the user has set a preference (FR-013).
    /// Engines that support biasing (Whisper via prompt, SpeechAnalyzer via N/A) may use it.
    let accentHint: AccentGroup?

    /// When `true`, the engine SHOULD include token-level confidence + timing on each segment.
    /// Engines that cannot may emit empty `tokens` arrays without violating the contract.
    let requestsTokenDetail: Bool

    init(locale: String = "en-US",
         accentHint: AccentGroup? = nil,
         requestsTokenDetail: Bool = true) {
        self.locale = locale
        self.accentHint = accentHint
        self.requestsTokenDetail = requestsTokenDetail
    }
}

/// Errors raised by `start(options:)`. Engines map their framework-specific failures into these.
enum SpeechEngineError: Error, Sendable, Equatable {
    case notAuthorized               // mic or speech permission denied
    case engineConfigurationFailed   // audio session / engine init failed
    case modelUnavailable            // WhisperKit model not downloaded yet
    case unsupportedLocale           // engine doesn't support requested locale
    case unsupportedDevice           // engine requires hardware this device lacks (e.g. A17 Pro)
}
