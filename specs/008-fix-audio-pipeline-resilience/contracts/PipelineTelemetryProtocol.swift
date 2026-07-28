//
//  PipelineTelemetryProtocol.swift
//  CONTRATO — Phase 1 de 008-fix-audio-pipeline-resilience
//
//  NO es código de producción. Define la superficie que la implementación debe respetar.
//  Destino: TranslatorApp/Domain/Interfaces/PipelineTelemetryProtocol.swift
//  Implementación: TranslatorApp/Data/Telemetry/PipelineTelemetry.swift (actor, OSLog)
//
//  Requisitos cubiertos: FR-001 … FR-008 · SC-026, SC-027, SC-028
//

import Foundation

/// Emisor de telemetría del pipeline. Domain solo conoce este protocolo;
/// la implementación concreta (OSLog) vive en Data — puerta G1.
///
/// Todos los métodos son `nonisolated` y no lanzan: la telemetría NUNCA puede
/// alterar el comportamiento de la ruta que instrumenta. Si el emisor falla,
/// falla en silencio.
protocol PipelineTelemetryProtocol: Sendable {

    // MARK: - Ciclo de vida de la sesión de reconocimiento (FR-001, FR-002)

    func sessionStart(sessionId: String,
                      engineId: String,
                      locale: String,
                      onDeviceRecognition: Bool)

    /// FR-002 — el evento cuya ausencia hace hoy imposible el diagnóstico.
    /// `errorDomain` y `errorCode` son opcionales SOLO cuando `reason != .error`.
    func sessionEnd(sessionId: String,
                    reason: SessionEndReason,
                    errorDomain: String?,
                    errorCode: Int?,
                    durationMs: Int,
                    restartIndex: Int)

    func restartBegin(sessionId: String, restartIndex: Int, trigger: RestartTrigger)

    func restartEnd(sessionId: String,
                    restartIndex: Int,
                    outcome: RestartOutcome,
                    totalMs: Int,
                    carryOverBufferCount: Int,
                    carryOverDurationMs: Int)

    /// Se emite cuando un reinicio falla dejando el pipeline sin tarea viva.
    /// Hoy este caso existe y solo produce un `logger.error` que no indica
    /// que el pipeline quedó muerto (AppleSpeechAnalyzerEngine.swift:151-154).
    func restartFailedFatal(sessionId: String,
                            errorDomain: String,
                            errorCode: Int,
                            continuationStillOpen: Bool)

    func watchdogFired(sessionId: String, msSinceLastTranscript: Int, msSinceSessionStart: Int)

    // MARK: - Continuidad del audio (FR-003)

    /// Emitir SOLO cuando `gapMs` supere el doble de `expectedMs`.
    /// A cadencia normal esto no debe emitir nada: un log por buffer inundaría la traza.
    func audioGap(sessionId: String, gapMs: Int, expectedMs: Int, bufferFrames: Int, sampleRate: Double)

    /// Mide directamente la ventana ciega. Con el tap permanente (research R4)
    /// el valor esperado es 0 en toda rotación; cualquier valor mayor es un defecto.
    func tapSwap(sessionId: String, restartIndex: Int, blindWindowMs: Int, carryOverBufferCount: Int)

    func tapFirstBufferAfterSwap(sessionId: String, restartIndex: Int, msSinceInstall: Int)

    /// Muestreo periódico, máximo una vez por segundo.
    func ringBufferState(bufferedMs: Int, bufferCount: Int, evictedSinceLast: Int)

    // MARK: - Segmentación y endpointing (FR-004)

    func stabilityTimerArmed(sessionId: String, delayMs: Int, reason: StabilityDelayReason, tailWords: Int)

    /// El evento que confirma o descarta la causa raíz de S2.
    /// `rescheduled == false` con `pendingTailWords > 0` es, por sí solo, el defecto.
    func stabilityTimerCancelled(sessionId: String,
                                 reason: StabilityCancelReason,
                                 rescheduled: Bool,
                                 pendingTailWords: Int,
                                 pendingAgeMs: Int)

    func stabilityTimerFired(sessionId: String, armedToFiredMs: Int, tailWords: Int, emitted: Bool)

    func pendingAge(sessionId: String, pendingAgeMs: Int, pendingWords: Int, ceilingMs: Int)

    func asrRestartDetected(sessionId: String, incomingWords: Int, committedWords: Int)

    /// Confirma directamente la causa raíz de S3 (TranscriptionViewModel.swift:174-182).
    func uiPrefixMismatch(sessionId: String,
                          branch: PrefixBranch,
                          committedWordCount: Int,
                          incomingWordCount: Int,
                          resultingBufferChars: Int)

    // MARK: - Cola de traducción (FR-005)

    func translationEnqueued(fragmentId: Int, chars: Int, queueDepth: Int)
    func translationStarted(fragmentId: Int, queueDepth: Int, waitedMs: Int)
    func translationDone(fragmentId: Int, translateMs: Int, endToEndMs: Int, queueDepth: Int)
    func translationFailed(fragmentId: Int, errorDescription: String, sourceChars: Int)
    func translationSkipped(fragmentId: Int, chars: Int, reason: String)
    func translationDedupDropped(fragmentId: Int)

    // MARK: - Sesión de audio (FR-006)

    func audioInterruption(type: InterruptionEdge, shouldResume: Bool, wasRecording: Bool)

    func audioRouteChange(reason: String,
                          previousInput: String?, newInput: String?,
                          previousSampleRate: Double?, newSampleRate: Double?,
                          previousChannels: Int?, newChannels: Int?)

    func audioConfigChange(engineIsRunning: Bool, inputFormat: String, tapFormat: String, formatsMatch: Bool)

    func mediaServicesReset(wasRecording: Bool, sessionId: String?)

    func audioSessionConfigured(category: String, mode: String, options: String,
                                sampleRate: Double, ioBufferDurationMs: Double, inputChannels: Int)

    func scenePhaseChange(phase: String, wasRecording: Bool, engineIsRunning: Bool)

    // MARK: - Export (FR-033)

    /// `missingCount` debe ser siempre 0 tras esta fase: un fragmento sin traducción
    /// lleva marcador y ocupa su línea, luego no "falta".
    func exportAlignment(enLineCount: Int, esLineCount: Int, unavailableCount: Int)
}

// MARK: - Enumeraciones de apoyo (Domain puro: sin tipos de framework — puerta G2)

enum SessionEndReason: String, Sendable {
    case isFinal, error, userStop, watchdog, interruption
}

enum RestartTrigger: String, Sendable {
    case isFinal, error, watchdog, manual, routeChange, configChange
}

enum RestartOutcome: String, Sendable { case ok, failed }

enum StabilityDelayReason: String, Sendable { case normal, lowQuality, incomplete }

/// Los cinco puntos donde hoy se cancela el temporizador. Cuatro de ellos
/// salen sin reprogramarlo (NLPSegmenterService.swift:72 frente a :74, :78, :89, :102).
enum StabilityCancelReason: String, Sendable {
    case newSegment, duplicateText, emptyPending, emptyTail, timeoutBranch
}

enum PrefixBranch: String, Sendable { case hasPrefix, wordCount, noCommitted }

enum InterruptionEdge: String, Sendable { case began, ended }

// La implementación debe incluir además un `NoopPipelineTelemetry` que conforme el protocolo
// con todos los métodos vacíos, para pruebas y para desactivar la telemetría sin ramificar en
// cada punto de llamada. No se esboza aquí porque exige repetir las ~30 firmas completas.
