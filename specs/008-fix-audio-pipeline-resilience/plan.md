# Implementation Plan: Resiliencia del pipeline de audio en vivo

**Branch**: `008-fix-audio-pipeline-resilience` | **Date**: 2026-07-28 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/008-fix-audio-pipeline-resilience/spec.md`
**Diagnóstico de origen**: [`DIAGNOSIS_AUDIO_PIPELINE.md`](../../DIAGNOSIS_AUDIO_PIPELINE.md) (Fase 1) — contiene toda la evidencia anclada a archivo y línea.

## Summary

Corregir cinco síntomas del pipeline de captura y traducción en vivo cuya causa raíz ya está identificada y anclada a código. El trabajo se agrupa en cuatro núcleos independientes más un habilitador transversal:

- **Habilitador — telemetría (US1).** Hoy el código de error que termina cada sesión de reconocimiento no se lee (`ContinuousSpeechListener.swift:123`). Sin eso, ninguna corrección se puede demostrar cerrada. Se introduce una capa de telemetría estructurada sobre OSLog con reloj continuo.
- **Núcleo A — rotación y reconciliación (US2, US6).** El tap del micrófono deja de desinstalarse y reinstalarse en cada rotación: pasa a instalarse una sola vez por sesión de grabación y a escribir en un contenedor de request intercambiable, con lo que la ventana ciega desaparece por construcción. En paralelo, la vista deja de comparar el texto entrante contra el prefijo acumulado de toda la sesión.
- **Núcleo B — endpointing (US3).** El temporizador de estabilidad deja de cancelarse sin reprogramarse (`NLPSegmenterService.swift:72` frente a `:74`), y el techo de retención pasa a vigilarse con un reloj propio en vez de oportunistamente.
- **Núcleo C — resiliencia de audio (US5).** Un coordinador único pasa a ser dueño de `AVAudioSession` y de todas sus notificaciones. La interrupción deja de terminar la sesión y pasa a suspenderla, con reanudación automática incluso cuando el usuario nunca atiende la alarma o la llamada.
- **Núcleo D — export (US7).** Se introduce una unidad de fragmento en memoria que empareja original y traducción, y un único formateador de texto que garantiza que ambos bloques tengan el mismo número de líneas.
- **US4** se reduce a retirar el motor local de la selección y comunicarlo.

**Enfoque técnico principal:** eliminar causas por construcción antes que añadir mitigaciones. El tap permanente elimina la ventana ciega en vez de medirla y acotarla; el reconocimiento en el dispositivo elimina el límite de duración del servidor en vez de reaccionar a él; el formateador único elimina la desalineación EN/ES en vez de detectarla.

## Technical Context

**Language/Version**: Swift 5.0 con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (concurrencia estricta)
**Primary Dependencies**: SwiftUI · Speech (`SFSpeechRecognizer`) · AVFoundation (`AVAudioEngine`, `AVAudioSession`) · NaturalLanguage (`NLTokenizer`, `NLTagger`) · Translation (Apple, en dispositivo) · SwiftData · OSLog. **Sin dependencias nuevas.** WhisperKit permanece como paquete SPM pero queda sin referenciar por el selector de motor.
**Storage**: SwiftData (`ConversationRecord`, `SessionQualityRecord`). **Sin migración de esquema** (decisión Q2).
**Testing**: XCTest. Los objetivos existentes (`TranslatorAppUITests`, `TranslatorAppEvaluationTests`) son andamiaje. Esta fase añade pruebas unitarias sobre los componentes puros de Domain y un protocolo de validación manual en dispositivo para lo que depende del hardware de audio.
**Target Platform**: iOS 26.1+ (`IPHONEOS_DEPLOYMENT_TARGET = 26.1`), iPhone y iPad (`TARGETED_DEVICE_FAMILY = "1,2"`)
**Project Type**: App iOS nativa, target Xcode único, Clean Architecture en tres capas
**Performance Goals**: hueco de captura p99 ≤ 50 ms en rotación · reanudación ≤ 2 000 ms tras interrupción · emisión por silencio ≤ 800 ms · p95 de latencia de traducción ≤ 1 500 ms
**Constraints**: sin bloquear el MainActor · sin trabajo con asignación de memoria en el hilo de render de audio · memoria estable ±10 % en 30 min · sin dependencias nuevas · convención de ≤250 líneas por archivo Swift
**Scale/Scope**: ~3 750 líneas Swift, 48 archivos. Esta fase toca ~14 archivos existentes y añade ~9.

### Contexto que condiciona el diseño

**El deployment target es iOS 26.1, no una versión anterior.** Tres consecuencias directas:

1. Los `#available(iOS 26.0, *)` presentes en el código (`DependencyContainer.swift:73`) son siempre verdaderos y son ruido muerto.
2. `SpeechAnalyzer` / `SpeechTranscriber` está disponible en **todos** los dispositivos soportados. Eliminaría la rotación de sesión por completo, y con ella la raíz de US6 y parte de US2. **No se adopta en esta fase** por decisión de alcance del spec (*"corregir el comportamiento existente, no rediseñar la arquitectura"*), pero queda evaluado en `research.md` §R6 y marcado como el candidato natural de la fase siguiente. Ver también **Riesgos** más abajo: es la decisión con más potencial de invalidar trabajo de esta fase.
3. `AppleSpeechAnalyzerEngine` está **mal nombrado**: usa `SFSpeechRecognizer`, no `SpeechAnalyzer` (`AppleSpeechAnalyzerEngine.swift:17,37,101`). Es un duplicado casi literal de `ContinuousSpeechListener`. Esta fase **unifica ambos** en vez de corregir el mismo defecto dos veces.

## Constitution Check

*GATE: debe pasar antes de Phase 0. Re-evaluado tras Phase 1.*

**Estado del archivo de constitución:** `.specify/memory/constitution.md` **es la plantilla sin rellenar** — todos sus principios son marcadores `[PRINCIPLE_N_NAME]`. No aporta ninguna restricción evaluable.

En su lugar, las puertas se derivan de las reglas reales y vigentes del proyecto, documentadas en `CLAUDE.md`. Se declara explícitamente para que no se lea como si hubiera pasado una revisión que no existe.

| # | Puerta (origen: `CLAUDE.md`) | Evaluación | Estado |
|---|---|---|---|
| G1 | Regla de dependencias `Presentation → Domain ← Data` | Los componentes nuevos puros (`LiveTailReconciler`, `ConversationTextFormatter`, `ConversationFragment`, `RecordingSessionState`, `TelemetryEvent`) viven en Domain e importan solo `Foundation`. `AudioSessionCoordinator` y `PipelineTelemetry` viven en Data porque importan AVFoundation y OSLog. Domain expone protocolos; Data los implementa | ✅ PASA |
| G2 | Domain no importa AVFoundation / SwiftUI / Speech | `RecordingSessionState` y `TelemetryEvent` modelan el estado sin tipos de framework. Los códigos de error se transportan como `(domain: String, code: Int)`, no como `NSError` | ✅ PASA |
| G3 | ViewModels nunca con `@StateObject` dentro de una View; solo composition root | No se crean ViewModels nuevos. `DependencyContainer` sigue siendo el único propietario | ✅ PASA |
| G4 | Sin bloquear el MainActor | La telemetría y el coordinador de audio son actores fuera del MainActor. El formateo de export es puro y síncrono, pero se ejecuta una vez al guardar, no en la ruta caliente | ✅ PASA |
| G5 | Concurrencia estricta de Swift 6 sin warnings; sin `@unchecked Sendable` casual | Se añade **un** `@unchecked Sendable`: el contenedor de request intercambiable, escrito desde el hilo de render. Justificado en Complexity Tracking con el mismo criterio que el `AudioRingBuffer` existente | ⚠️ JUSTIFICADO |
| G6 | Sin añadir dependencias ni gestores de paquetes | Cero dependencias nuevas. WhisperKit permanece como SPM ya presente, sin referenciar | ✅ PASA |
| G7 | Convención de ≤250 líneas por archivo Swift | `ContinuousSpeechListener` (277 líneas) ya la incumple y va a crecer. Se divide extrayendo la captura de audio a `AudioCaptureSession`. Ningún archivo nuevo supera 250 | ✅ PASA |
| G8 | Sin commits, sin push, sin crear ramas sin preguntar | Esta fase no commitea nada. La rama 008 se creó con autorización explícita | ✅ PASA |
| G9 | Logging con OSLog, subsistema `com.spanesso.TraslatorApp`, categoría por componente | La telemetría usa el mismo subsistema y añade la categoría `Telemetry`. No sustituye los `Logger` existentes | ✅ PASA |

**Veredicto: la puerta pasa.** Una desviación justificada (G5).

### Re-evaluación tras Phase 1

Revisado contra `data-model.md` y `contracts/`. Nada cambia, y dos puertas quedan reforzadas por el diseño:

- **G1 / G2 confirmadas por los contratos.** `PipelineTelemetryProtocol` transporta los errores como `(errorDomain: String, errorCode: Int)` en vez de `NSError`, y `AudioSessionEvent` usa `AudioInterruptionReason` en vez de tipos de `AVAudioSession`. Domain queda sin importar AVFoundation ni Speech. El comprobante está automatizado en `quickstart.md` §8.
- **G5 sin cambios.** El diseño no introdujo ningún `@unchecked Sendable` adicional: `AudioSessionCoordinatorProtocol` es un `Actor` y `PipelineTelemetryProtocol` es `Sendable` con implementación de actor. Sigue siendo uno solo.
- **G7 resuelta, no solo mitigada.** `ContinuousSpeechListener` (277 líneas, ya incumplía) desaparece; la captura se extrae a `AudioCaptureSession` y el reconocimiento a `AppleSFSpeechEngine`.
- **G4 verificada en el punto delicado.** `ConversationTextFormatter` es puro y síncrono, y solo se invoca al guardar o exportar — nunca en la ruta de parciales del ASR.

**Acción recomendada aparte:** rellenar `.specify/memory/constitution.md` con las reglas de `CLAUDE.md`, para que `/speckit.plan` tenga puertas reales en futuras features. Fuera del alcance de esta fase.

## Project Structure

### Documentation (this feature)

```text
specs/008-fix-audio-pipeline-resilience/
├── plan.md                          # Este archivo
├── spec.md                          # Qué y por qué
├── research.md                      # Phase 0 — decisiones técnicas resueltas
├── data-model.md                    # Phase 1 — entidades y transiciones de estado
├── quickstart.md                    # Phase 1 — protocolo de validación en dispositivo
├── contracts/                       # Phase 1 — contratos de interfaz
│   ├── PipelineTelemetryProtocol.swift
│   ├── AudioSessionCoordinatorProtocol.swift
│   ├── LiveTailReconciler.swift
│   └── ConversationTextFormatter.swift
├── checklists/
│   └── requirements.md
└── tasks.md                         # Phase 2 — lo genera /speckit.tasks, NO este comando
```

### Source Code (repository root)

```text
TranslatorApp/
├── App/
│   └── DependencyContainer.swift            # MOD — retirar motor local; inyectar telemetría
│                                            #       y coordinador; quitar el observer ad-hoc
├── Domain/
│   ├── Entities/
│   │   ├── ConversationFragment.swift       # NUEVO — unidad emparejada EN/ES en memoria
│   │   ├── RecordingSessionState.swift      # NUEVO — active / suspended / stopped
│   │   ├── TelemetryEvent.swift             # NUEVO — evento estructurado, sin tipos de framework
│   │   ├── AudioInterruptionReason.swift    # NUEVO — causa modelada, no un booleano
│   │   ├── TranslatorState.swift            # MOD — + suspendedByAudioInterruption
│   │   └── EnginePreference.swift           # MOD — marcar la opción del motor local no disponible
│   ├── Interfaces/
│   │   ├── PipelineTelemetryProtocol.swift  # NUEVO
│   │   └── AudioSessionCoordinatorProtocol.swift # NUEVO
│   ├── Services/
│   │   ├── LiveTailReconciler.swift         # NUEVO — puro; saca de la vista la lógica de US2
│   │   ├── ConversationTextFormatter.swift  # NUEVO — puro; único formateador de export
│   │   ├── NLPSegmenterService.swift        # MOD — US3: reprogramar timer; techo con reloj propio
│   │   └── QualityMetricsService.swift      # MOD — desacoplar velocidad de habla de "baja calidad"
│   └── UseCases/
│       ├── TranscribeAudioUseCase.swift     # MOD — telemetría del pump
│       └── SaveConversationUseCase.swift    # MOD — validar alineación de líneas
├── Data/
│   ├── Audio/
│   │   ├── AudioCaptureSession.swift        # NUEVO — dueño de AVAudioEngine y del tap permanente
│   │   ├── RecognitionRequestBox.swift      # NUEVO — contenedor intercambiable (@unchecked Sendable)
│   │   ├── AudioSessionCoordinator.swift    # NUEVO — dueño de AVAudioSession + notificaciones
│   │   ├── AudioRingBuffer.swift            # MOD — copia sin asignación en el hilo de render
│   │   └── EmptySegmentFilter.swift         # MOD — reloj continuo en vez de uptime
│   ├── Telemetry/
│   │   └── PipelineTelemetry.swift          # NUEVO — actor; OSLog estructurado
│   ├── SpeechEngines/
│   │   ├── AppleSFSpeechEngine.swift        # NUEVO — unifica los dos motores SF duplicados
│   │   ├── AppleSpeechAnalyzerEngine.swift  # ELIMINADO — duplicado; mal nombrado
│   │   ├── LegacySFSpeechEngine.swift       # ELIMINADO — absorbido
│   │   └── WhisperKitEngine.swift           # SIN TOCAR — queda en el repo, sin referenciar
│   ├── ContinuousSpeechListener.swift       # ELIMINADO — absorbido en AppleSFSpeechEngine
│   └── Repositories/…                       # sin cambios
├── Presentation/
│   ├── ViewModels/
│   │   └── TranscriptionViewModel.swift     # MOD — fragmentos; suspensión; reconciliación
│   └── Views/
│       ├── LiveTranscriptionView.swift      # MOD — telemetría de traducción; estado suspendido
│       ├── LiveTranscriptionPanes.swift     # MOD — render desde fragmentos
│       ├── ConversationDetailView.swift     # MOD — usar el formateador único
│       └── Settings/EnginePreferenceView.swift # MOD — motor local no disponible
└── Info.plist                               # MOD — UIBackgroundModes: audio (decisión Q3)
```

**Structure Decision**: se conserva la Clean Architecture en tres capas existente con `DependencyContainer` como raíz de composición. No se introducen módulos ni targets nuevos. Los componentes nuevos se colocan según qué frameworks necesitan importar: puros en `Domain/`, ligados a AVFoundation u OSLog en `Data/`.

Dos consolidaciones deliberadas, ambas reductoras de superficie:

- **`ContinuousSpeechListener` + `LegacySFSpeechEngine` + `AppleSpeechAnalyzerEngine` → `AppleSFSpeechEngine`.** Hoy son tres archivos que implementan la misma lógica de rotación dos veces, con defectos divergentes: solo uno tiene watchdog, y solo uno cierra el stream cuando el reinicio falla (`ContinuousSpeechListener.swift:174-177` frente a `AppleSpeechAnalyzerEngine.swift:151-154`). Corregir US5 y US6 dos veces en paralelo garantiza que vuelvan a divergir. La consolidación **reduce** el código neto.
- **La captura de audio sale del motor a `AudioCaptureSession`.** Es lo que permite que el tap sea permanente y que la rotación sea un intercambio de puntero.

## Complexity Tracking

| Violación | Por qué es necesaria | Alternativa más simple, y por qué se rechaza |
|---|---|---|
| **G5** — un `@unchecked Sendable` nuevo (`RecognitionRequestBox`) | El closure del tap corre en el hilo de render de audio y debe leer cuál es el request activo sin `await`. Un `actor` obligaría a un salto asíncrono por cada buffer, que es exactamente lo que hoy provoca pérdida. Es el mismo razonamiento, ya aceptado en el proyecto, que justifica `AudioRingBuffer` (`AudioRingBuffer.swift:16-19`) | **Actor con `await` en el tap:** descartada — introduce latencia no acotada en el hilo de render y reordena buffers. **`OSAllocatedUnfairLock`:** es la implementación elegida *dentro* de la caja; el `@unchecked Sendable` sigue siendo necesario para el tipo que la envuelve. El alcance se limita a una clase de ~30 líneas con dos operaciones |
| **Consolidación de tres motores en uno** — cambio estructural en una fase declarada de corrección | Mantener los duplicados obliga a aplicar US5 y US6 dos veces sobre código que ya divergió una vez. El resultado neto es menos código, no más | **Corregir ambos por separado:** descartada — duplica el esfuerzo de implementación y de validación, y deja garantizado que la próxima corrección vuelva a aplicarse solo a uno |

## Riesgos

| # | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| R1 | **`SpeechAnalyzer` deja obsoleto parte del trabajo.** Con deployment target 26.1, migrar a `SpeechAnalyzer` eliminaría la rotación de sesión y con ella la razón de ser de US6 y de la reconciliación de US2 | Alto | El trabajo de US1, US3, US5 y US7 es independiente del motor y se conserva íntegro. El de US6 y parte de US2 se perdería. **Se recomienda decidir esto antes de `/speckit.tasks`** — ver `research.md` §R6 y la nota al final |
| R2 | El modo de audio en segundo plano requiere justificación ante la revisión de App Store | Medio | Consecuencia asumida de la decisión Q3, ya registrada en el spec. La justificación es literalmente la función del producto |
| R3 | La reanudación tras interrupción depende de que iOS entregue la notificación de fin, que no está garantizada en todos los casos | Medio | Sondeo de respaldo además de la notificación. Diseño en `research.md` §R2 |
| R4 | Los umbrales de 50 ms y 2 000 ms no son alcanzables en dispositivos antiguos | Bajo | La telemetría de US1 los mide antes de que se intente cumplirlos: si un umbral resulta físicamente inalcanzable, se renegocia con datos, no por impresión |
| R5 | El árbol arrastra los cambios sin commitear de 006 y 007 | Medio | Es la línea base declarada del spec. Cualquier regresión atribuida a 008 debe contrastarse contra ese punto de partida, no contra `main` |

## Phase 0 — Research

Ver [`research.md`](./research.md). Resuelve siete decisiones técnicas: reconocimiento en dispositivo, semántica de reanudación de interrupciones, elección de reloj monotónico, cambios de ruta con tap permanente, copia sin asignación en el hilo de render, `SpeechAnalyzer` como alternativa evaluada, y formato de telemetría legible desde el dispositivo.

## Phase 1 — Design & Contracts

Ver [`data-model.md`](./data-model.md), [`contracts/`](./contracts/) y [`quickstart.md`](./quickstart.md).

## Phase 2 — Tasks

**No la genera este comando.** Ejecutar `/speckit.tasks` a continuación.
