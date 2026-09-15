//
//  SelectingSpeechEngine.swift
//  TranslatorApp
//
//  Chooses the recogniser at every start, and never leaves the user unable to record
//  (SpeechAnalyzer migration, 2026-09-15).
//
//  SpeechAnalyzer is preferred. It can still be unavailable — a device without support, a model
//  that cannot be downloaded right now, a start that fails — and in every one of those cases the
//  classic SFSpeechRecognizer engine is used instead. Two failures are never masked by a fallback:
//  missing permissions (the classic engine needs them too) and a stop that arrived during start.
//

import Foundation
import OSLog
import os

actor SelectingSpeechEngine: SpeechEngineProtocol {

    private let preferred: any SpeechEngineProtocol
    private let fallback: any SpeechEngineProtocol
    private let preferredId: EngineId
    private let fallbackId: EngineId
    private let usePreferred: @Sendable () -> Bool
    private let telemetry: any PipelineTelemetryProtocol
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "EngineSelection")

    /// The engine running — or starting. A stop must reach it even while `start` is suspended.
    private var current: (any SpeechEngineProtocol)?
    private let selectedId: OSAllocatedUnfairLock<EngineId>

    nonisolated var engineId: EngineId { selectedId.withLock { $0 } }

    init(preferred: any SpeechEngineProtocol,
         preferredId: EngineId,
         fallback: any SpeechEngineProtocol,
         fallbackId: EngineId,
         usePreferred: @escaping @Sendable () -> Bool,
         telemetry: any PipelineTelemetryProtocol) {
        self.preferred = preferred
        self.preferredId = preferredId
        self.fallback = fallback
        self.fallbackId = fallbackId
        self.usePreferred = usePreferred
        self.telemetry = telemetry
        self.selectedId = OSAllocatedUnfairLock(initialState: preferredId)
    }

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        if usePreferred() {
            current = preferred
            selectedId.withLock { $0 = preferredId }
            do {
                return try await preferred.start(options: options)
            } catch let error as SpeechEngineError where error == .notAuthorized {
                current = nil
                throw error
            } catch is CancellationError {
                current = nil
                throw CancellationError()
            } catch {
                let nsError = error as NSError
                telemetry.engineFallback(TelemetrySessionId.new(),
                                         from: preferredId.rawValue,
                                         to: fallbackId.rawValue,
                                         reason: "\(nsError.domain)/\(nsError.code)")
                logger.error("[EngineSelection] \(self.preferredId.rawValue, privacy: .public) could not start (\(nsError.domain, privacy: .public)/\(nsError.code)); using \(self.fallbackId.rawValue, privacy: .public)")
            }
        }
        current = fallback
        selectedId.withLock { $0 = fallbackId }
        do {
            return try await fallback.start(options: options)
        } catch {
            current = nil
            throw error
        }
    }

    func stop() async {
        guard let running = current else { return }
        current = nil
        await running.stop()
    }
}
