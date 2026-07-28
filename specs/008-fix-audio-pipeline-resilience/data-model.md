# Phase 1 — Data Model

**Feature**: 008-fix-audio-pipeline-resilience
**Fecha**: 2026-07-28

Todas las entidades nuevas viven en `Domain/Entities/` e importan **solo `Foundation`** (puerta G2). Ninguna se persiste: la decisión Q2 mantiene el esquema de SwiftData sin cambios.

---

## 1. `ConversationFragment` — NUEVA (solo en memoria)

La unidad de emparejamiento que hoy no existe. Sustituye a los dos arrays paralelos `emittedPhrases: [String]` y `translatedSentences: [TranslationEntry]` de `TranscriptionViewModel.swift:37-38`, cuya desalineación es la causa de S5.

| Campo | Tipo | Reglas |
|---|---|---|
| `id` | `Int` | Monotónico dentro de la sesión, desde 0. Es el índice de línea en ambos bloques del export |
| `sourceText` | `String` | Inglés. No vacío tras recortar espacios. **Inmutable una vez creado** |
| `translation` | `TranslationOutcome` | Estado de la traducción. Ver abajo |
| `sourceConfidence` | `Float` | 0…1. Se propaga desde la frase del segmentador |
| `createdAt` | `ContinuousClock.Instant` | Solo para telemetría. **No se persiste** (decisión Q2: sin marca de tiempo por fragmento) |

```swift
enum TranslationOutcome: Sendable, Equatable {
    case pending                  // encolada, aún sin resolver
    case translated(String)       // texto traducido, no vacío
    case unavailable(Reason)      // resuelta como ausente — SIEMPRE ocupa su línea

    enum Reason: String, Sendable {
        case failed               // el servicio de traducción lanzó un error
        case tooShort             // descartada antes de traducir (LiveTranscriptionView.swift:138)
        case emptyResult          // el servicio devolvió texto vacío
        case timedOut             // no resuelta al drenar en el stop
        case serviceUnavailable   // prepareTranslation falló; toda la sesión
    }
}
```

### Invariante central

> Un fragmento **nunca desaparece**. Una traducción que falla pasa de `.pending` a `.unavailable(razón)`; nunca se elimina el fragmento ni se omite su línea.

Es lo que hace estructuralmente cierto SC-020 (los dos bloques tienen el mismo número de líneas). Hoy la ausencia se materializa como un `append` que no ocurre (`LiveTranscriptionView.swift:150-162`), que es indistinguible de "no había nada".

### Transiciones

```
             creado con el commit del segmentador
                          │
                          ▼
                      .pending ──────────────┐
                          │                  │
        traducción OK     │                  │  falló / vacía / corta /
                          ▼                  ▼  timeout / servicio caído
                  .translated(texto)   .unavailable(razón)
                          │                  │
                          └────── terminal ──┘
```

`.pending` es el **único** estado no terminal. Al detener la grabación, todo fragmento que siga en `.pending` tras el drenaje de 3 000 ms (SC-023) pasa a `.unavailable(.timedOut)`.

### Reglas de deduplicación (FR-040)

La deduplicación se aplica **al fragmento**, una sola vez, en el momento del commit, con la clave normalizada que hoy solo se usa del lado español (`TranscriptionViewModel.swift:238-243`). Elimina la asimetría en la que dos frases inglesas que solo difieren en puntuación producen dos entradas inglesas y una española.

---

## 2. `RecordingSessionState` — NUEVA

El estado que hoy no existe y cuya ausencia hace que una alarma desatendida sea indistinguible de un stop deliberado.

```swift
enum RecordingSessionState: Sendable, Equatable {
    case idle
    case active
    case suspended(AudioInterruptionReason)
    case stopping
}
```

| Estado | Motor de audio | Sesión de audio | Stream | Histórico | Interfaz |
|---|---|---|---|---|---|
| `idle` | parado | inactiva | cerrado | vacío | botón de grabar |
| `active` | corriendo | activa | abierto | crece | grabando |
| `suspended` | parado | **activa** | **abierto** | **conservado** | "en pausa, se reanudará sola" |
| `stopping` | parando | desactivándose | drenando | conservado | guardando |

**La fila de `suspended` es el corazón de US5.** Que la sesión de audio siga activa y el stream siga abierto es lo que hace que la reanudación sea reanudar y no volver a empezar.

### Transiciones

```
 idle ──[usuario pulsa grabar]──► active
                                    │  ▲
      [interrupción empieza]────────┘  │
                 │                     │
                 ▼                     │
            suspended ─────────────────┘
                 │        [interrupción termina, por notificación
                 │         O por sondeo exitoso — R2]
                 │
                 └──[60 s de fallos consecutivos]──► stopping ──► idle (con aviso)

 active ──[usuario pulsa detener]──► stopping ──► idle
```

**Prohibido:** `suspended → idle` directo. Toda salida de `suspended` pasa por `active` (reanudación) o por `stopping` (rendición explícita tras 60 s). Es lo que impide que una interrupción termine la sesión, que es el defecto actual.

### `AudioInterruptionReason`

```swift
enum AudioInterruptionReason: String, Sendable {
    case systemInterruption    // llamada, alarma, asistente de voz
    case routeChanged          // auriculares conectados o desconectados
    case configurationChanged  // el motor de audio cambió de configuración
    case mediaServicesReset    // los servicios de medios se reiniciaron
}
```

Modelada como causa, no como booleano, porque FR-029 exige que el mensaje al usuario describa la causa real. Es lo que hoy falla: cualquier interrupción se reporta como problema de permisos (`TranscriptionViewModel.swift:127`).

---

## 3. `TelemetryEvent` — NUEVA

Evento estructurado, sin tipos de framework, para respetar la puerta G2. Los errores viajan como dominio y código sueltos, no como `NSError`.

```swift
struct TelemetryEvent: Sendable {
    let kind: Kind                     // prefijo estable en mayúsculas (R7)
    let sessionId: String              // 4 primeros caracteres del UUID de sesión
    let at: ContinuousClock.Instant    // R3
    let fields: [(String, String)]     // pares clave=valor, orden estable
}
```

| Grupo | Tipos | Requisito |
|---|---|---|
| Ciclo de vida | `SESSION_START`, `SESSION_END`, `RESTART_BEGIN`, `RESTART_END`, `RESTART_FAILED_FATAL`, `WATCHDOG_FIRED` | FR-001, FR-002 |
| Audio | `AUDIO_GAP`, `TAP_SWAP`, `TAP_FIRST_BUFFER`, `RINGBUFFER_STATE` | FR-003 |
| Segmentación | `STAB_ARMED`, `STAB_CANCEL`, `STAB_FIRED`, `PENDING_AGE`, `ASR_RESTART_DETECTED`, `UI_PREFIX_MISMATCH` | FR-004 |
| Traducción | `TR_ENQUEUE`, `TR_START`, `TR_DONE`, `TR_FAILED`, `TR_SKIPPED`, `TR_DEDUP_DROP` | FR-005 |
| Sesión de audio | `AUDIO_INTERRUPTION`, `AUDIO_ROUTE_CHANGE`, `AUDIO_CONFIG_CHANGE`, `MEDIA_SERVICES_RESET`, `AUDIO_SESSION_CONFIGURED`, `SCENE_PHASE` | FR-006 |
| Export | `EXPORT_ALIGNMENT` | FR-033 |

**`SESSION_END` es el evento cuya ausencia hace hoy imposible el diagnóstico.** Campos obligatorios: `reason`, `errDomain`, `errCode`, `durMs`, `restartIdx`.

**Regla de privacidad:** ningún `TelemetryEvent` transporta texto transcrito. Solo recuentos, duraciones y códigos.

---

## 4. Entidades existentes modificadas

### `TranslatorState` — `Domain/Entities/TranslatorState.swift`

```swift
case suspendedByAudioInterruption(AudioInterruptionReason)   // NUEVO
```

Se añade al `==` manual (el enum tiene valores asociados, `TranslatorState.swift:17-32`). Con él, `LiveTranscriptionView.alertTitle` (`:266-274`) deja de mostrar "Permission Required" ante una interrupción y `spanishPane` puede mostrar el estado de pausa.

### `EnginePreference` — `Domain/Entities/EnginePreference.swift`

```swift
var isAvailable: Bool {                       // NUEVO
    switch self {
    case .auto, .appleOnly:   return true
    case .whisperPreferred:   return false    // retirado en 008 — decisión Q1
    }
}
```

El caso `.whisperPreferred` **se conserva** en vez de eliminarse: hay usuarios con ese valor ya guardado en preferencias, y borrar el caso rompería la decodificación. `DependencyContainer` lo trata como `.auto`, y `EnginePreferenceView` lo muestra deshabilitado con explicación (FR-019).

### `EngineId` — `Domain/Entities/EngineId.swift`

Sin cambios estructurales. `appleSpeechAnalyzer` y `legacyAppleSFSpeech` quedan ambos apuntando al motor consolidado; se conservan por compatibilidad con los registros de calidad ya guardados.

---

## 5. Entidades persistidas — SIN CAMBIOS

`ConversationRecord` (`Data/Models/ConversationRecord.swift:11-14`) y `ConversationEntity` conservan exactamente sus cuatro campos. **Sin migración de SwiftData** (decisión Q2).

Lo que cambia es cómo se **rellenan** esos campos. Hoy:

```swift
englishText: emittedPhrases.joined(separator: " "),        // espacios
spanishText: translatedSentences.map(\.text).joined("\n")  // saltos de línea
```

Separadores distintos, recuentos independientes, correspondencia irrecuperable.

A partir de esta fase, `ConversationTextFormatter` produce ambos bloques desde el **mismo** array de fragmentos, con el **mismo** separador y **una línea por fragmento**:

```
englishText  = fragments.map(\.sourceText).joined(separator: "\n")
spanishText  = fragments.map(translationLine).joined(separator: "\n")
```

donde `translationLine` devuelve el texto traducido, o el marcador `[traducción no disponible: <razón>]` para `.unavailable`. `.pending` no puede llegar aquí: el drenaje del stop lo convierte antes en `.timedOut`.

**Compatibilidad hacia atrás (FR-044).** Las conversaciones guardadas antes de esta fase tienen un bloque inglés unido por espacios y recuentos de línea distintos. Se leen y se exportan sin error; simplemente no ofrecen la garantía de correspondencia. El lector no intenta inferirla: no hay heurística, y una inferencia equivocada sería peor que no ofrecer la garantía.

---

## 6. Mapa de requisitos a entidades

| Entidad | Requisitos | Sustituye a |
|---|---|---|
| `ConversationFragment` | FR-037…FR-040, FR-043 · SC-020, SC-021, SC-022 | Dos arrays paralelos en `TranscriptionViewModel.swift:37-38` |
| `TranslationOutcome` | FR-039 · SC-021 | El `catch` sin `append` en `LiveTranscriptionView.swift:150-162` |
| `RecordingSessionState` | FR-023, FR-024, FR-025, FR-030 · SC-006, SC-007 | El booleano `isRecording` (`TranscriptionViewModel.swift:30`) |
| `AudioInterruptionReason` | FR-029 | El estado `.permissionDenied` reutilizado incorrectamente |
| `TelemetryEvent` | FR-001…FR-008 · SC-026, SC-027, SC-028 | Nada — hoy no existe |
| `TranslatorState.suspendedByAudioInterruption` | FR-025, FR-029 | El mensaje falso de permisos |
| `EnginePreference.isAvailable` | FR-017, FR-019 | La selección de `DependencyContainer.swift:52-66` |
