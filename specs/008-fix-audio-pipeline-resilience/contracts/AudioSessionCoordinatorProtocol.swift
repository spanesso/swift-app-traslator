//
//  AudioSessionCoordinatorProtocol.swift
//  CONTRATO — Phase 1 de 008-fix-audio-pipeline-resilience
//
//  NO es código de producción.
//  Destino: TranslatorApp/Domain/Interfaces/AudioSessionCoordinatorProtocol.swift
//  Implementación: TranslatorApp/Data/Audio/AudioSessionCoordinator.swift
//
//  Requisitos cubiertos: FR-022 … FR-033 · SC-005, SC-006, SC-007, SC-008, SC-010, SC-011
//
//  Hoy la responsabilidad de AVAudioSession está repartida entre tres motores que la
//  configuran de forma inconsistente (.default en dos, .measurement en el tercero) y un
//  observer suelto en el composition root que solo escucha el INICIO de la interrupción.
//  Este coordinador pasa a ser el único dueño.
//

import Foundation

protocol AudioSessionCoordinatorProtocol: Actor {

    /// Estado observable por el ViewModel. Emite en cada transición.
    var events: AsyncStream<AudioSessionEvent> { get }

    /// Configura y activa la sesión de audio. Idempotente.
    /// Categoría, modo y opciones IDÉNTICOS para todos los motores (FR-022).
    func activate() async throws

    /// Desactiva la sesión. Solo al detener de verdad — NUNCA durante una
    /// suspensión (FR-030): mantenerla activa es lo que permite reanudar.
    func deactivate() async

    /// Empieza a observar interrupciones, cambios de ruta, cambios de configuración
    /// y reinicio de servicios de medios. Debe llamarse antes de `activate()`.
    func startObserving() async

    /// Deja de observar y retira los observadores. Hoy el observer existente
    /// nunca se retira (DependencyContainer.swift:113-127).
    func stopObserving() async

    /// Intento único de reactivación. Devuelve `true` si la sesión quedó activa.
    /// Es la primitiva del sondeo de respaldo de research R2: su éxito es la señal
    /// REAL de que la interrupción terminó, sin depender de que llegue la notificación.
    func attemptReactivation() async -> Bool
}

/// Causa modelada, no booleano: FR-029 exige que el mensaje al usuario describa la causa
/// real. Hoy cualquier interrupción se reporta como problema de permisos
/// (TranscriptionViewModel.swift:127). Destino: Domain/Entities/AudioInterruptionReason.swift
enum AudioInterruptionReason: String, Sendable, Equatable {
    case systemInterruption    // llamada, alarma, asistente de voz
    case routeChanged          // auriculares conectados o desconectados
    case configurationChanged  // el motor de audio cambió de configuración
    case mediaServicesReset    // los servicios de medios se reiniciaron
}

/// Lo que el coordinador comunica hacia arriba. Sin tipos de AVFoundation:
/// el ViewModel vive en Presentation y no debe importar Data — puerta G1.
enum AudioSessionEvent: Sendable, Equatable {

    /// Suspender la captura. NO terminar la sesión: el histórico se conserva
    /// y el stream sigue abierto (data-model §2).
    case interrupted(AudioInterruptionReason)

    /// Reanudar. Emitido tanto por notificación como por sondeo exitoso.
    case resumed

    /// El formato del nodo de entrada cambió: hay que reinstalar el tap
    /// con el formato NUEVO, nunca con uno cacheado (research R4).
    case captureNeedsRebuild(AudioInterruptionReason)

    /// 60 s de reactivaciones fallidas. Única salida legítima de `suspended`
    /// hacia `stopping` (data-model §2).
    case giveUp(afterMs: Int)
}

// MARK: - Parámetros de la máquina de reanudación (research R2)

enum ResumePolicy {
    /// Cadencia del sondeo de respaldo. Compromiso entre cumplir SC-005 (≤2 000 ms)
    /// y no consumir batería sondeando.
    static let pollIntervalMs = 2_000

    /// Techo total antes de rendirse e informar al usuario.
    static let giveUpAfterMs = 60_000

    /// Presupuesto para reconstruir la captura tras un cambio de ruta (SC-008).
    static let rebuildBudgetMs = 1_000
}

// MARK: - Configuración única de la sesión de audio (FR-022)

/// Un solo sitio donde vive la configuración. Hoy está triplicada e inconsistente:
/// ContinuousSpeechListener.swift:67 y AppleSpeechAnalyzerEngine.swift:69 usan `.default`,
/// WhisperKitEngine.swift:71 usa `.measurement`, que desactiva el control automático de
/// ganancia y la reducción de ruido — justo lo que la feature 005 identificó como crítico
/// para habla acentuada, distante o baja.
enum AudioSessionConfig {
    static let category = "record"
    static let mode = "default"        // NUNCA .measurement: conserva AGC y reducción de ruido
    static let options = "duckOthers"
    /// Decisión Q3: capturar con la pantalla bloqueada exige declarar el modo de
    /// audio en segundo plano en Info.plist. Consecuencia aceptada y registrada.
    static let requiresBackgroundAudioMode = true
}
