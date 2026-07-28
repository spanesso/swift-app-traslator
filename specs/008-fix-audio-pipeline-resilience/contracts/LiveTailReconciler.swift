//
//  LiveTailReconciler.swift
//  CONTRATO — Phase 1 de 008-fix-audio-pipeline-resilience
//
//  NO es código de producción.
//  Destino: TranslatorApp/Domain/Services/LiveTailReconciler.swift
//
//  Requisito: US2 · FR-009 … FR-012 · SC-016
//
//  PROBLEMA QUE RESUELVE (causa raíz de S3, diagnóstico Fase 1 §H6)
//  --------------------------------------------------------------
//  Hoy la lógica vive inline en TranscriptionViewModel.swift:174-182 y compara el texto
//  entrante contra `committedPrefix`, que es el join de TODAS las frases emitidas de la
//  sesión (TranscriptionViewModel.swift:248-253) y nunca se limpia dentro de una sesión.
//
//  Tras la primera rotación del reconocedor (~1 min de reunión) la nueva sesión empieza
//  su transcripción desde cero:
//    · `full.hasPrefix(committed)` es falso
//    · se cae a la rama de conteo de palabras
//    · `cw` = palabras de TODA la reunión (p.ej. 300), `aw.count` = 4
//    · `aw.count > cw` es falso  →  currentBuffer = ""  PERMANENTE
//
//  Una sesión de reconocimiento, acotada a ~60 s, jamás vuelve a superar el conteo
//  acumulado de la reunión entera. El panel en vivo queda vacío para siempre.
//
//  El segmentador SÍ tiene el equivalente correcto (NLPSegmenterService.swift:217-222).
//  La vista no. Este componente lleva esa lógica a Domain, donde es puro y comprobable.
//

import Foundation

/// Reconcilia el texto acumulado del reconocedor con el histórico ya confirmado
/// para producir la cola en vivo aún sin confirmar.
///
/// Puro y determinista: sin fechas, sin E/S, sin estado global. Comprobable con
/// pruebas unitarias sin hardware de audio — que es justo lo que hoy no se puede hacer.
struct LiveTailReconciler {

    /// Frontera de la sesión de reconocimiento actual dentro del histórico global.
    ///
    /// LA CORRECCIÓN CLAVE: la comparación se hace contra lo confirmado DESDE que
    /// arrancó la sesión de reconocimiento en curso, no contra toda la reunión.
    /// `AppleSFSpeechEngine` la reinicia en cada rotación.
    private(set) var committedInCurrentRecognitionSession: String = ""
    private(set) var committedWordCountInSession: Int = 0

    /// Llamar al confirmar una frase mientras la sesión de reconocimiento sigue viva.
    mutating func commit(_ phrase: String) { fatalError("contract sketch") }

    /// Llamar cuando el motor rota. Reinicia la frontera: el reconocedor nuevo
    /// empieza desde cero, luego lo confirmado antes deja de ser comparable.
    /// El histórico visible NO se toca (FR-012, decisión de la feature 007).
    mutating func recognitionSessionDidRestart() { fatalError("contract sketch") }

    /// Produce la cola en vivo a partir del texto acumulado del reconocedor.
    ///
    /// Contrato:
    ///  · Prefijo coincide           → devuelve el sufijo
    ///  · Recuento entrante ≤ confirmado en sesión → detecta reinicio, se reinicia y
    ///    devuelve el texto entero. NUNCA devuelve "" por esta vía — ese es el defecto actual
    ///  · Sin confirmado en sesión   → devuelve el texto entero
    func liveTail(from recognizerFullText: String) -> ReconcileResult { fatalError("contract sketch") }
}

struct ReconcileResult: Sendable, Equatable {
    let tail: String
    let branch: Branch              // se emite como telemetría (UI_PREFIX_MISMATCH)
    let detectedRestart: Bool

    enum Branch: String, Sendable { case hasPrefix, wordCount, noCommitted, restartDetected }
}

//  CASOS DE PRUEBA OBLIGATORIOS (sin ellos la regresión de S3 vuelve sin avisar)
//  ---------------------------------------------------------------------------
//  1. Sesión limpia, sin confirmado → tail == texto completo, branch == .noCommitted
//  2. El texto continúa lo confirmado → tail == sufijo, branch == .hasPrefix
//  3. Texto entrante MÁS CORTO que lo confirmado en sesión (rotación)
//     → detectedRestart == true, tail == texto completo, branch == .restartDetected
//     ← ESTE es el caso que hoy produce "" para siempre
//  4. Reunión larga: confirmar 300 palabras, rotar, entrar 4 palabras
//     → tail == esas 4 palabras. NO "". Es la regresión exacta de S3
//  5. Rotaciones repetidas: 10 ciclos de commit+restart
//     → la cola sigue produciéndose correctamente en las diez
//  6. El confirmado global de la reunión sigue creciendo sin afectar a la reconciliación
//     → prueba que la frontera es por sesión de reconocimiento, no global
