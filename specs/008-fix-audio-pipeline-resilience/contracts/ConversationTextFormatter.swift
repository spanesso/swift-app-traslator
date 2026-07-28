//
//  ConversationTextFormatter.swift
//  CONTRATO — Phase 1 de 008-fix-audio-pipeline-resilience
//
//  NO es código de producción.
//  Destino: TranslatorApp/Domain/Services/ConversationTextFormatter.swift
//
//  Requisitos: US7 · FR-037 … FR-044 · SC-020, SC-021, SC-022, SC-025
//
//  PROBLEMA QUE RESUELVE (causa raíz de S5, diagnóstico Fase 1 §H8)
//  ---------------------------------------------------------------
//  Hoy hay DOS formateadores duplicados con el mismo formato:
//    · TranscriptionViewModel.swift:45-49   (sesión viva)
//    · ConversationDetailView.swift:24-30   (desde el historial)
//
//  Y ambos unen con separadores DISTINTOS por idioma:
//    englishText = emittedPhrases.joined(separator: " ")          ← espacios
//    spanishText = translatedSentences.map(\.text).joined("\n")   ← saltos de línea
//
//  Con recuentos independientes y cuatro filtros que reducen solo el lado español
//  (LiveTranscriptionView.swift:138 y :150, TranscriptionViewModel.swift:217 y :224),
//  la correspondencia original↔traducción es irrecuperable.
//
//  Decisión Q2: NO se migra el esquema. La correspondencia pasa a ser POSICIONAL
//  POR NÚMERO DE LÍNEA, garantizada por este único formateador.
//

import Foundation

// Definidas en data-model.md §1. Se reproducen aquí para que el contrato se sostenga solo.
// Destino: TranslatorApp/Domain/Entities/ConversationFragment.swift
struct ConversationFragment: Sendable, Identifiable {
    let id: Int                        // monotónico; ES el índice de línea en ambos bloques
    let sourceText: String             // inglés, no vacío, inmutable
    var translation: TranslationOutcome
    let sourceConfidence: Float
}

enum TranslationOutcome: Sendable, Equatable {
    case pending
    case translated(String)
    case unavailable(Reason)

    enum Reason: String, Sendable {
        case failed, tooShort, emptyResult, timedOut, serviceUnavailable
    }
}

/// Único productor de texto de conversación de toda la app.
/// Puro, sin estado, sin E/S. `TranscriptionViewModel` y `ConversationDetailView`
/// pasan a delegar aquí — la duplicación desaparece.
enum ConversationTextFormatter {

    /// Marcador de traducción ausente. NUNCA se omite la línea: omitirla es
    /// exactamente el defecto actual, donde una ausencia es indistinguible de
    /// "no había nada".
    static func unavailableMarker(_ reason: TranslationOutcome.Reason) -> String { fatalError("contract sketch") }

    /// Bloque inglés: una línea por fragmento.
    /// OJO: cambia respecto al formato actual, que une con espacios. El cambio es
    /// obligatorio — sin el mismo separador en ambos lados, la correspondencia
    /// posicional no puede existir.
    static func englishBlock(_ fragments: [ConversationFragment]) -> String { fatalError("contract sketch") }

    /// Bloque español: una línea por fragmento, con marcador donde falte.
    /// GARANTÍA: mismo número de líneas que `englishBlock` para la misma entrada.
    static func spanishBlock(_ fragments: [ConversationFragment]) -> String { fatalError("contract sketch") }

    /// Documento exportable completo, con las cabeceras que ya usa la app.
    static func exportDocument(_ fragments: [ConversationFragment]) -> String { fatalError("contract sketch") }

    /// Comprobación del invariante. `SaveConversationUseCase` la llama antes de
    /// persistir (FR-033) y la telemetría emite el resultado (EXPORT_ALIGNMENT).
    /// Debe devolver `true` SIEMPRE tras esta fase.
    static func linesAreAligned(english: String, spanish: String) -> Bool { fatalError("contract sketch") }

    /// Compatibilidad hacia atrás (FR-044). Las conversaciones guardadas antes de
    /// esta fase tienen el bloque inglés unido por espacios y recuentos distintos.
    /// Se muestran y exportan sin error, SIN intentar inferir la correspondencia:
    /// no hay heurística fiable, y una inferencia equivocada sería peor que no
    /// ofrecer la garantía.
    static func isLegacyFormat(english: String, spanish: String) -> Bool { fatalError("contract sketch") }
}

//  INVARIANTES (verificar en pruebas unitarias — sin hardware)
//  ----------------------------------------------------------
//  I1. Para cualquier [ConversationFragment]:
//        englishBlock(f).lines.count == spanishBlock(f).lines.count == f.count
//      ← SC-020. Es el invariante central de US7
//
//  I2. Todo fragmento .unavailable produce una línea NO VACÍA con marcador.  ← SC-021
//
//  I3. Ningún fragmento .pending llega al formateador: el drenaje del stop
//      (3 000 ms, SC-023) lo convierte antes en .unavailable(.timedOut)
//
//  I4. Entrada vacía → ambos bloques vacíos, cero líneas. No "(no transcript)":
//      los placeholders son cosa de la capa de presentación, no del formateador
//
//  I5. exportDocument es determinista: misma entrada, misma salida byte a byte
//
//  CASOS DE PRUEBA OBLIGATORIOS
//  ----------------------------
//  1. Todos traducidos                    → N líneas a cada lado
//  2. Uno falló                           → N líneas, una con marcador       ← el bug de S5
//  3. Todos fallaron (servicio caído)     → N líneas inglesas, N marcadores  ← LiveTranscriptionView.swift:122-131
//  4. Texto con saltos de línea internos  → NO rompe el recuento de líneas   ← trampa del separador
//  5. Cero fragmentos                     → ambos vacíos, sin error
//  6. Documento de formato antiguo        → isLegacyFormat == true, se exporta sin error
