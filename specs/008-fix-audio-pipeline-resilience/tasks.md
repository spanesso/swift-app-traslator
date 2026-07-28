---
description: "Task list for 008-fix-audio-pipeline-resilience"
---

# Tasks: Resiliencia del pipeline de audio en vivo

**Input**: Design documents from `/specs/008-fix-audio-pipeline-resilience/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: se incluyen **solo** los que los contratos de Phase 1 declaran obligatorios (`LiveTailReconciler.swift` y `ConversationTextFormatter.swift` los listan explícitamente), más las transiciones de estado de US5. No es una suite TDD completa: son las pruebas sin hardware que impiden que las regresiones de S2, S3 y S5 vuelvan sin avisar.

**Organización**: agrupadas por historia de usuario.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: puede ejecutarse en paralelo (archivos distintos, sin dependencias pendientes)
- **[Story]**: US1…US7 según `spec.md`

## Nota honesta sobre la estructura

Esta feature **no es greenfield**: corrige un pipeline existente. Dos consecuencias que conviene tener claras antes de empezar:

1. **La fase Foundational es grande** (14 tareas). Contiene la consolidación de motores y la infraestructura de audio y telemetría. La alternativa —instrumentar y parchear tres motores duplicados que van a desaparecer— sería trabajo tirado. US5 y US6 reescriben la misma ruta de audio; hacerlo dos veces garantiza que vuelva a divergir, que es exactamente cómo llegó el código a su estado actual.
2. **Las historias son independientemente *validables*, no independientemente *desplegables*.** Cada checkpoint verifica criterios concretos del spec, pero ninguna historia se entrega sin la Foundational.

---

## Phase 1: Setup

**Purpose**: línea base medible y andamiaje de pruebas. Sin el paso 1, ninguna mejora posterior es demostrable.

- [ ] T001 Capturar la línea base según `specs/008-fix-audio-pipeline-resilience/quickstart.md` §0: grabar 10 min en dispositivo físico con `log stream --device --predicate 'subsystem == "com.spanesso.TraslatorApp"'`, guardar como `baseline.log` fuera del repo, y anotar motor en uso, número de rotaciones, si el panel EN se congela, traducciones frente a pausas reales, y recuentos de línea del export
- [X] T002 Crear los directorios `TranslatorApp/Data/Telemetry/` y `TranslatorApp/Domain/Interfaces/` (este último ya existe; verificar) y añadirlos al target `TranslatorApp` en `TranslatorApp.xcodeproj`
- [X] T003 [P] Verificar que el target `TranslatorAppTests` puede alojar pruebas unitarias puras de Domain: añadir un `DomainUnitTests.swift` vacío que compile e importe `@testable import TranslatorApp`. **No crear un target nuevo** — el target `TranslatorAppTests` ya existe en el pbxproj con sync group; basta crear el directorio
- [X] T004 [P] Añadir la categoría `Telemetry` a la convención de logging documentada en `CLAUDE.md` (sección Logging), junto a `Speech`, `UseCase`, `Segmenter`, `Quality`, `ViewModel`, `UI`

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: infraestructura que TODAS las historias necesitan. Telemetría, propiedad única de la sesión de audio, y consolidación de los tres motores duplicados en uno.

**⚠️ CRITICAL**: ninguna historia puede empezar hasta que esta fase esté completa.

### Telemetría — infraestructura (research R3, R7)

- [X] T005 [P] Crear `TranslatorApp/Domain/Entities/TelemetryEvent.swift` con `TelemetryEvent` y las enumeraciones de apoyo (`SessionEndReason`, `RestartTrigger`, `RestartOutcome`, `StabilityDelayReason`, `StabilityCancelReason`, `PrefixBranch`, `InterruptionEdge`) según `data-model.md` §3. Solo `import Foundation` — puerta G2
- [X] T006 [P] Crear `TranslatorApp/Domain/Interfaces/PipelineTelemetryProtocol.swift` copiando la superficie de `contracts/PipelineTelemetryProtocol.swift`. Los errores viajan como `(errorDomain: String, errorCode: Int)`, nunca como `NSError`
- [X] T007 Crear `TranslatorApp/Data/Telemetry/PipelineTelemetry.swift`: actor que conforma `PipelineTelemetryProtocol` sobre `OSLog` con subsistema `com.spanesso.TraslatorApp` y categoría `Telemetry`. Formato de línea: prefijo estable en mayúsculas + pares `clave=valor` (research R7). Usa `ContinuousClock` (research R3), **nunca** `DispatchTime.uptimeNanoseconds` ni `Date`. Ningún método emite texto transcrito
- [X] T008 [P] Añadir `NoopPipelineTelemetry` en `TranslatorApp/Data/Telemetry/PipelineTelemetry.swift`: conforma el protocolo con todos los métodos vacíos, para pruebas y para desactivar sin ramificar en cada punto de llamada
- [X] T009 Instanciar `PipelineTelemetry` en `TranslatorApp/App/DependencyContainer.swift` e inyectarlo en el grafo. Es el primer objeto que se construye en `init()`, antes que cualquier motor

### Sesión de audio — propietario único (contracts/AudioSessionCoordinatorProtocol.swift)

- [X] T010 [P] Crear `TranslatorApp/Domain/Entities/AudioInterruptionReason.swift` con los cuatro casos de `data-model.md` §2
- [X] T011 [P] Crear `TranslatorApp/Domain/Interfaces/AudioSessionCoordinatorProtocol.swift` con el protocolo, `AudioSessionEvent`, `ResumePolicy` y `AudioSessionConfig` según `contracts/AudioSessionCoordinatorProtocol.swift`
- [X] T012 Crear `TranslatorApp/Data/Audio/AudioSessionCoordinator.swift`: actor dueño único de `AVAudioSession`. Configura `.record` + `.default` + `.duckOthers` en un solo sitio (FR-022), expone `events: AsyncStream<AudioSessionEvent>`, e implementa `activate()`, `deactivate()`, `startObserving()`, `stopObserving()` y `attemptReactivation()`. **En esta fase solo observa y emite**; la máquina de suspensión y reanudación es US5
- [X] T013 Eliminar `setupInterruptionObserver()` de `TranslatorApp/App/DependencyContainer.swift:113-127` y sustituirlo por la construcción de `AudioSessionCoordinator`. El observador antiguo nunca se retiraba y solo escuchaba `.began`

### Consolidación de motores (plan.md → Structure Decision)

- [X] T014 Crear `TranslatorApp/Data/Audio/RecognitionRequestBox.swift`: contenedor intercambiable del request activo, con `OSAllocatedUnfairLock` interno y `@unchecked Sendable`. Documentar la justificación en cabecera con el mismo criterio que `AudioRingBuffer.swift:16-19` — puerta G5. Máximo ~40 líneas
- [X] T015 Crear `TranslatorApp/Data/Audio/AudioCaptureSession.swift`: dueño de `AVAudioEngine`. Instala el tap **una sola vez** por sesión de grabación y escribe en `RecognitionRequestBox` y en `AudioRingBuffer`. Lee el formato del nodo de entrada **en el momento de instalar**, nunca desde un valor cacheado (research R4, corrige `ContinuousSpeechListener.swift:83`). Expone `rebuildCapture()` para cambios de ruta
- [X] T016 Crear `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift`: actor que conforma `SpeechEngineProtocol` y unifica `ContinuousSpeechListener`, `LegacySFSpeechEngine` y `AppleSpeechAnalyzerEngine`. Delega la captura en `AudioCaptureSession`. Conserva el watchdog (hoy solo en uno de los tres) y el cierre del stream ante fallo de reinicio (hoy solo en el otro, comparar `ContinuousSpeechListener.swift:174-177` con `AppleSpeechAnalyzerEngine.swift:151-154`). Fija `requiresOnDeviceRecognition = true` previa comprobación de `supportsOnDeviceRecognition` (research R1). Máximo 250 líneas — puerta G7
- [X] T017 Eliminar `TranslatorApp/Data/ContinuousSpeechListener.swift`, `TranslatorApp/Data/SpeechEngines/LegacySFSpeechEngine.swift` y `TranslatorApp/Data/SpeechEngines/AppleSpeechAnalyzerEngine.swift`, y quitar sus referencias de `TranslatorApp.xcodeproj`
- [X] T018 Actualizar `TranslatorApp/App/DependencyContainer.swift` para construir `AppleSFSpeechEngine` con `AudioCaptureSession`, `AudioSessionCoordinator` y la telemetría. Eliminar la construcción incondicional del antiguo listener (`DependencyContainer.swift:42`)

**Checkpoint**: la app compila, graba y transcribe con un solo motor consolidado. Los `[SESSION_START]` y `[SESSION_END]` ya aparecen en el log. Nada más está corregido todavía.

---

## Phase 3: User Story 4 — La app solo selecciona motores que funcionan (Priority: P1)

**Goal**: retirar el motor local de la selección, que hoy reproduce los cinco síntomas a la vez en dispositivos A17 Pro+ con el modelo instalado.

**Independent Test**: arrancar en un dispositivo A17 Pro+ con el modelo instalado y verificar en el log que usa `appleSFSpeech`, que el panel español se llena y que Guardar y Exportar aparecen al detener.

**Por qué va primero**: es la historia P1 más pequeña (5 tareas) y la de mayor efecto inmediato para los usuarios afectados. Retirar un motor entero también reduce la superficie de todo lo que viene después.

- [X] T019 [P] [US4] Añadir `isAvailable` a `TranslatorApp/Domain/Entities/EnginePreference.swift` según `data-model.md` §4: `.auto` y `.appleOnly` devuelven `true`, `.whisperPreferred` devuelve `false`. **No eliminar el caso** — hay usuarios con ese valor ya guardado y borrarlo rompería la decodificación
- [X] T020 [US4] Modificar la selección de `TranslatorApp/App/DependencyContainer.swift:52-66` para que **nunca** construya `WhisperKitEngine`: `.whisperPreferred` se trata como `.auto`, y `.auto` siempre resuelve a `AppleSFSpeechEngine`. Conservar la línea canónica `[Container] engine=` (FR-017, FR-018, FR-021)
- [X] T021 [P] [US4] Modificar `TranslatorApp/Presentation/Views/Settings/EnginePreferenceView.swift` para deshabilitar la opción no disponible y explicar por qué, en vez de ofrecerla como una opción que falla en silencio (FR-019). Actualizar `footerText` (`:110-119`), que hoy promete WhisperKit
- [X] T022 [US4] Impedir que `TranslatorApp/Data/Coordinators/BackgroundAssetsCoordinator.swift` ofrezca o inicie la descarga del modelo local mientras el motor esté retirado (FR-020). No borrar el modelo ya descargado en dispositivos de usuarios
- [X] T023 [US4] Retirar de `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` el diálogo de consentimiento de descarga (`:104-109`) y el banner de progreso (`:61-63`, `:193-215`) mientras el motor esté retirado

**Checkpoint**: **SC-019** verificable. Cero dispositivos seleccionan el motor local.

---

## Phase 4: User Story 1 — Ver por qué falló una sesión (Priority: P1)

**Goal**: colocar los puntos de instrumentación que convierten los "a veces" en datos medibles. La infraestructura ya existe (Foundational); esto son los puntos de llamada.

**Independent Test**: grabar 10 min forzando una interrupción y un cambio de auriculares; con solo el log, alguien que no conozca el código explica en ≤5 min por qué terminó cada sesión.

- [X] T024 [US1] Emitir `SESSION_START` y `SESSION_END` en `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift`. **`SESSION_END` es el evento cuya ausencia hace hoy imposible el diagnóstico**: leer `(error as NSError).domain` y `.code` del callback de reconocimiento y emitirlos siempre. Hoy el error solo se compara contra `nil` (FR-001, FR-002, SC-027)
- [X] T025 [US1] Emitir `RESTART_BEGIN`, `RESTART_END` y `RESTART_FAILED_FATAL` en `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift`, con `restartIndex`, `trigger`, `outcome` y `totalMs`
- [X] T026 [US1] Emitir `WATCHDOG_FIRED` en `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift` con `msSinceLastTranscript` y `msSinceSessionStart`
- [X] T027 [P] [US1] Emitir `AUDIO_GAP`, `TAP_SWAP` y `TAP_FIRST_BUFFER` en `TranslatorApp/Data/Audio/AudioCaptureSession.swift`. `AUDIO_GAP` solo cuando el delta supere el doble de la duración nominal del buffer: un log por buffer inundaría la traza (FR-003)
- [X] T028 [P] [US1] Emitir `RINGBUFFER_STATE` en `TranslatorApp/Data/Audio/AudioRingBuffer.swift`, muestreado como máximo una vez por segundo
- [X] T029 [P] [US1] Emitir `STAB_ARMED`, `STAB_CANCEL`, `STAB_FIRED`, `PENDING_AGE` y `ASR_RESTART_DETECTED` en `TranslatorApp/Domain/Services/NLPSegmenterService.swift`. `STAB_CANCEL` debe llevar `reason` y `rescheduled` (FR-004) — es el evento que confirma o descarta la causa raíz de S2
- [X] T030 [P] [US1] Emitir `TR_ENQUEUE`, `TR_START`, `TR_DONE`, `TR_FAILED`, `TR_SKIPPED` y `TR_DEDUP_DROP` en `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` y `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`. Ampliar los `[TRANSLATE-START]` y `[TRANSLATE-DONE]` existentes (`LiveTranscriptionView.swift:141`, `:146`) con `queueDepth` y `waitedMs` (FR-005)
- [X] T031 [US1] Emitir `AUDIO_INTERRUPTION`, `AUDIO_ROUTE_CHANGE`, `AUDIO_CONFIG_CHANGE`, `MEDIA_SERVICES_RESET` y `AUDIO_SESSION_CONFIGURED` en `TranslatorApp/Data/Audio/AudioSessionCoordinator.swift` (FR-006)
- [X] T032 [US1] Emitir `SCENE_PHASE` desde `TranslatorApp/App/TranslatorAppApp.swift` observando `scenePhase`, con `wasRecording` y `engineIsRunning` (FR-006)

**Checkpoint**: **SC-026, SC-027, SC-028** verificables. Los filtros de `quickstart.md` §1 ya son ejecutables. A partir de aquí, cada historia se valida con datos y no por impresión.

---

## Phase 5: User Story 3 — Toda pausa produce una traducción (Priority: P1)

**Goal**: corregir el temporizador de estabilidad, que hoy se cancela sin reprogramarse en cuatro salidas anticipadas.

**Independent Test**: leer un guion de 20 frases con pausas de ≥1 s y verificar que se producen exactamente 20 traducciones.

### Tests

- [X] T033 [P] [US3] Escribir en `TranslatorAppTests/` la prueba de que un parcial repetido idéntico **no** cancela definitivamente la emisión pendiente: alimentar el segmentador con el mismo texto N veces y verificar que la frase se emite igualmente. **Debe fallar antes de T034**
- [X] T034 [P] [US3] Escribir en `TranslatorAppTests/` la prueba del techo de retención: una cola pendiente que deja de recibir segmentos nuevos se emite antes de 3 000 ms. **Debe fallar antes de T036**

### Implementación

- [X] T035 [US3] Reprogramar el temporizador de estabilidad antes de **cada** salida anticipada en `TranslatorApp/Domain/Services/NLPSegmenterService.swift`. Hoy `stabilityTimer?.cancel()` está en `:72`, antes de los `continue` de `:74` (texto duplicado), `:78` (pendiente vacío), `:89` (rama de timeout) y `:102` (cola vacía). La de `:74` es la crítica: el reconocedor reemite el mismo parcial durante la pausa, que es su comportamiento normal (FR-013)
- [X] T036 [US3] Sustituir la comprobación oportunista de `maxPendingInterval` (`NLPSegmenterService.swift:82`, que solo se evalúa al llegar un segmento nuevo) por un temporizador independiente que vigile la antigüedad de la cola pendiente. Bajar el techo de 6 000 ms a 3 000 ms (FR-014, SC-013)
- [X] T037 [US3] Eliminar el acoplamiento entre velocidad de habla y calidad en `TranslatorApp/Domain/Services/QualityMetricsService.swift:120`: `avgWordsPerSecond > 4.0` marca hoy como "baja calidad" a un hablante rápido, lo que sube el umbral de 700 a 1 200 ms justo cuando debería emitir antes (FR-015, SC-015)
- [X] T038 [US3] Revisar `isLikelyIncomplete` en `TranslatorApp/Domain/Services/NLPSegmenterService.swift:186-206`: `!hasVerb && wordCount > 2` (`:204`) devuelve `true` para casi cualquier cola parcial y dispara constantemente el umbral lento de 2 500 ms. Acotarlo para que solo aplique al indicador de palabra funcional colgante (`:202`)
- [X] T039 [US3] Verificar que las frases cortas y completas siguen emitiéndose (`NLPSegmenterService.swift:53-62`, `forceEmit`): probar con `"Yes."`, `"Okay."` y `"Right."` (FR-016)

**Checkpoint**: **SC-012, SC-013, SC-014, SC-015** verificables. `grep '\[STAB_CANCEL\]' | grep 'rescheduled=false'` sale vacío.

---

## Phase 6: User Story 2 — La transcripción en vivo no se congela (Priority: P1)

**Goal**: sacar de la vista la reconciliación de parciales y compararla contra la sesión de reconocimiento en curso, no contra la reunión entera.

**Independent Test**: hablar 10 min sin parar y verificar que el texto en vivo se actualiza en los minutos 1, 3, 5 y 10, cruzando al menos ocho rotaciones.

### Tests

- [X] T040 [P] [US2] Escribir en `TranslatorAppTests/` los seis casos obligatorios listados en `contracts/LiveTailReconciler.swift`. El caso 4 —confirmar 300 palabras, rotar, entrar 4 palabras, esperar esas 4 y no `""`— es la regresión exacta de S3. **Deben fallar antes de T041**

### Implementación

- [X] T041 [US2] Crear `TranslatorApp/Domain/Services/LiveTailReconciler.swift` según `contracts/LiveTailReconciler.swift`: puro, sin fechas ni E/S, con `commit`, `recognitionSessionDidRestart` y `liveTail(from:)` devolviendo `ReconcileResult` (FR-009, FR-010, FR-011)
- [X] T042 [US2] Exponer en `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift` una señal de rotación consumible desde arriba, para que el reconciliador sepa cuándo reiniciar su frontera
- [X] T043 [US2] Sustituir la lógica inline de `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift:174-182` por una llamada a `LiveTailReconciler`. Eliminar `committedPrefix`, `committedWordCount` y `refreshCommittedPrefix()` (`:72-73`, `:248-253`), que son el mecanismo que hoy congela el panel
- [X] T044 [US2] Conectar la señal de rotación de T042 a `recognitionSessionDidRestart()` en `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`
- [X] T045 [US2] Emitir `UI_PREFIX_MISMATCH` con `branch`, `committedWordCount` e `incomingWordCount` desde el punto de reconciliación en `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`, para poder observar en campo que la rama degenerada dejó de ocurrir
- [X] T046 [US2] Verificar en `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` que el histórico completo de la sesión se conserva sin recortes (FR-012): no reintroducir ningún `removeFirst()` sobre el array de fragmentos, decisión de la feature 007

**Checkpoint**: **SC-016** verificable. El panel EN sigue vivo a los 10 minutos.

---

## Phase 7: User Story 5 — Recuperación automática de interrupciones (Priority: P1)

**Goal**: que una alarma o llamada, **incluso sin atender**, suspenda la sesión en vez de terminarla, y que se reanude sola.

**Independent Test**: con una grabación activa, dejar sonar una alarma sin tocar el teléfono hasta que se apague sola; la grabación debe reanudarse sin ninguna acción.

### Tests

- [X] T047 [P] [US5] Escribir en `TranslatorAppTests/` las transiciones de `RecordingSessionState` de `data-model.md` §2, incluida la prohibición de `suspended → idle` directo: toda salida de `suspended` pasa por `active` o por `stopping`. **Debe fallar antes de T049**

### Implementación

- [X] T048 [P] [US5] Crear `TranslatorApp/Domain/Entities/RecordingSessionState.swift` con `idle`, `active`, `suspended(AudioInterruptionReason)` y `stopping` (`data-model.md` §2)
- [X] T049 [US5] Añadir `suspendedByAudioInterruption(AudioInterruptionReason)` a `TranslatorApp/Domain/Entities/TranslatorState.swift`, incluyéndolo en el `==` manual (`:17-32`, el enum tiene valores asociados)
- [X] T050 [US5] Implementar en `TranslatorApp/Data/Audio/AudioSessionCoordinator.swift` la rama de **fin** de interrupción, que hoy no existe en todo el repo: leer `shouldResume` y emitir `.resumed` (FR-024)
- [X] T051 [US5] Implementar el sondeo de respaldo de research R2 en `TranslatorApp/Data/Audio/AudioSessionCoordinator.swift`: mientras el estado sea suspendido, llamar a `attemptReactivation()` cada 2 000 ms; su éxito es la señal real de que la interrupción terminó. Rendirse tras 60 000 ms emitiendo `.giveUp`. **Es lo que cubre el caso desatendido**: la notificación de fin no está garantizada
- [X] T052 [US5] Implementar la observación de `routeChangeNotification` en `TranslatorApp/Data/Audio/AudioSessionCoordinator.swift` y emitir `.captureNeedsRebuild(.routeChanged)` (FR-026). Cero ocurrencias hoy en el repo
- [X] T053 [US5] Implementar la observación de `AVAudioEngineConfigurationChange` y de `mediaServicesWereResetNotification` en `TranslatorApp/Data/Audio/AudioSessionCoordinator.swift` (FR-027, FR-028). Cero ocurrencias hoy
- [X] T054 [US5] Implementar `rebuildCapture()` en `TranslatorApp/Data/Audio/AudioCaptureSession.swift`: parar el motor, reinstalar el tap **leyendo el formato nuevo del nodo de entrada**, y arrancar, dentro del presupuesto de 1 000 ms (SC-008, research R4)
- [X] T055 [US5] Sustituir `handleAudioInterruption()` en `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift:126-131` por la máquina de suspensión: **no** llamar a `stopRecording()`, **no** poner `.permissionDenied`, conservar el histórico y mantener el stream abierto (FR-023, FR-029, SC-007, SC-010)
- [X] T056 [US5] Garantizar en `TranslatorApp/Data/Audio/AudioSessionCoordinator.swift` que `setActive(false)` **nunca** se llama durante una suspensión, solo al detener de verdad (FR-030). Hoy no hay ninguna llamada a `setActive(false)` en el repo; al añadirla, este es el matiz que la hace correcta
- [X] T057 [US5] Mostrar el estado de suspensión en `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` y `LiveTranscriptionPanes.swift`: indicar que está en pausa por audio del sistema y que se reanudará sola. Corregir `alertTitle` (`:266-274`), que hoy muestra "Permission Required" ante cualquier interrupción (FR-025, FR-029)
- [X] T058 [US5] Añadir `UIBackgroundModes` con el valor `audio` a `TranslatorApp/Info.plist` (decisión Q3, FR-032). Verificar que el watchdog de `AppleSFSpeechEngine` detecta la suspensión del sistema pese al modo declarado e informa en vez de perder el tramo (FR-033)

**Checkpoint**: **SC-005, SC-006, SC-007, SC-008, SC-010, SC-011** verificables. Especialmente `quickstart.md` §5b, que exige dejar sonar una alarma real sin tocar el teléfono.

---

## Phase 8: User Story 6 — Sin pérdida de palabras en la rotación (Priority: P2)

**Goal**: llevar a cero la ventana ciega de la rotación, por construcción y no por ajuste.

**Independent Test**: leer un texto conocido de 5 min a ritmo rápido cruzando al menos cuatro rotaciones y comparar palabra por palabra contra el original.

- [X] T059 [US6] Rotar la sesión de reconocimiento en `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift` **sin tocar el tap**: sustituir el request dentro de `RecognitionRequestBox` y nada más. Sin `removeTap` ni `installTap`, que es lo que hoy abre la ventana (FR-034, research R4)
- [X] T060 [US6] Verificar con el evento `TAP_SWAP` que `blindWindowMs` es **0** en toda rotación, y auditar `TranslatorApp/Data/Audio/AudioCaptureSession.swift` y `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift` para confirmar que no queda ningún `removeTap` en la ruta de rotación. Con el tap permanente el valor esperado no es "pequeño": es cero (SC-001, SC-002)
- [X] T061 [US6] Eliminar el `Task.sleep(nanoseconds: 300_000_000)` de `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift:120`, que descarta 300 ms deterministas en cada reinicio manual, y hacer que el reinicio manual siga la misma ruta que la rotación automática (FR-035, SC-003)
- [X] T062 [US6] Rearmar el watchdog de `TranslatorApp/Data/SpeechEngines/AppleSFSpeechEngine.swift` con la **actividad real** del reconocimiento, no solo al arrancar una sesión. Hoy `scheduleWatchdog()` solo se llama desde el arranque (`ContinuousSpeechListener.swift:103`), nunca desde la actualización de transcript (`:187`), así que fuerza rotaciones innecesarias cada 65 s cuando la sesión vive más (FR-036)
- [X] T063 [P] [US6] Preasignar el anillo de buffers en `TranslatorApp/Data/Audio/AudioRingBuffer.swift` al arrancar la sesión y hacer que el tap solo copie muestras sobre un slot existente. Eliminar la asignación de `AVAudioPCMBuffer` del hilo de render (`:66-81`) y reducir el lock a dos índices enteros (research R5)
- [X] T064 [P] [US6] Sustituir `DispatchTime.now().uptimeNanoseconds` por `ContinuousClock` en `TranslatorApp/Data/Audio/EmptySegmentFilter.swift:26`. `uptimeNanoseconds` se detiene mientras el dispositivo duerme, lo que con la decisión Q3 deja de ser un detalle (research R3)
- [X] T065 [US6] Verificar en el log que el número de `[RESTART_BEGIN]` cae drásticamente respecto a `baseline.log`, como efecto de `requiresOnDeviceRecognition = true` (T016, research R1). Registrar la comparación de confianza por token frente a la línea base: si la precisión se degrada de forma inaceptable, la decisión R1 se revierte **con datos**

**Checkpoint**: **SC-001, SC-002, SC-003, SC-004** verificables. `grep '\[TAP_SWAP\]' | grep -v 'blindMs=0'` sale vacío.

---

## Phase 9: User Story 7 — Export bilingüe íntegro (Priority: P2)

**Goal**: que ambos bloques del export tengan siempre el mismo número de líneas, con marcador explícito donde falte la traducción.

**Independent Test**: grabar 20 frases provocando al menos un fallo de traducción, exportar, y verificar que ambos bloques tienen el mismo recuento de líneas y que la línea afectada lleva marcador.

### Tests

- [X] T066 [P] [US7] Escribir en `TranslatorAppTests/` los cinco invariantes y los seis casos obligatorios listados en `contracts/ConversationTextFormatter.swift`. El caso 4 —texto con saltos de línea internos que no debe romper el recuento— es la trampa del separador. **Deben fallar antes de T068**

### Implementación

- [X] T067 [P] [US7] Crear `TranslatorApp/Domain/Entities/ConversationFragment.swift` con `ConversationFragment` y `TranslationOutcome` según `data-model.md` §1. El invariante central: un fragmento **nunca desaparece**; una traducción fallida pasa a `.unavailable(razón)`
- [X] T068 [US7] Crear `TranslatorApp/Domain/Services/ConversationTextFormatter.swift` según `contracts/ConversationTextFormatter.swift`. **Ambos bloques usan el mismo separador y una línea por fragmento** (FR-038). Es el cambio que hace posible la correspondencia posicional
- [X] T069 [US7] Sustituir los dos arrays paralelos de `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift:37-38` por un único array de `ConversationFragment`. Es la desalineación estructural que causa S5
- [X] T070 [US7] Modificar el consumo de traducción en `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift:137-163` para que **todas** las rutas resuelvan el fragmento: el `catch` (`:150`) pasa a `.unavailable(.failed)`, el descarte por longitud (`:138`) a `.unavailable(.tooShort)`, y el fallo de `prepareTranslation()` (`:122-131`) marca la sesión entera como `.unavailable(.serviceUnavailable)` (FR-039)
- [X] T071 [US7] Unificar la deduplicación en `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`: aplicar la clave normalizada de `dedupKey` (`:238-243`) **al fragmento**, una sola vez, en vez de igualdad exacta del lado inglés (`:192`) y normalizada del lado español (`:224`). Hoy dos frases que solo difieren en puntuación producen dos entradas inglesas y una española (FR-040)
- [X] T072 [US7] Implementar el drenaje al detener en `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift:208-213`: esperar hasta 3 000 ms a las traducciones en vuelo y convertir a `.unavailable(.timedOut)` las que sigan pendientes, antes de habilitar el guardado (FR-041, SC-023)
- [X] T073 [US7] Sustituir `exportText` (`TranscriptionViewModel.swift:45-49`) y el formateador duplicado de `TranslatorApp/Presentation/Views/ConversationDetailView.swift:24-30` por llamadas a `ConversationTextFormatter`. La duplicación desaparece
- [X] T074 [US7] Validar la alineación en `TranslatorApp/Domain/UseCases/SaveConversationUseCase.swift` antes de persistir, y emitir `EXPORT_ALIGNMENT`. Añadir el guard simétrico para el lado español, que hoy no existe (`:26-29` solo valida el inglés) (FR-033, FR-043)
- [X] T075 [US7] Renderizar desde fragmentos en `TranslatorApp/Presentation/Views/LiveTranscriptionPanes.swift`: los dos `ForEach` independientes por índice (`:34`, `:101`) pasan a recorrer un único array. Mostrar el marcador de traducción no disponible en el panel español
- [X] T076 [US7] Garantizar la compatibilidad hacia atrás en `TranslatorApp/Presentation/Views/ConversationDetailView.swift` con `isLegacyFormat`: las conversaciones guardadas antes de esta fase se muestran y exportan sin error, **sin intentar inferir** la correspondencia (FR-044, SC-025)

**Checkpoint**: **SC-020, SC-021, SC-022, SC-023, SC-024, SC-025** verificables.

---

## Phase 10: Polish & Cross-Cutting Concerns

- [ ] T077 Ejecutar el protocolo completo de `specs/008-fix-audio-pipeline-resilience/quickstart.md` en dispositivo físico y marcar los 28 criterios **con evidencia de log o medición adjunta**, no por inspección visual
- [ ] T078 Ejecutar la sesión combinada de 30 min de `quickstart.md` §5e: tres interrupciones (al menos una desatendida) y dos cambios de ruta. Verificar memoria estable ±10 % con Instruments (SC-016, SC-017, SC-018)
- [X] T079 [P] Verificar las puertas del constitution check de `quickstart.md` §8: cero warnings de concurrencia, cero `import AVFoundation` y `import SwiftUI` bajo `TranslatorApp/Domain/`, ningún archivo Swift nuevo por encima de 250 líneas, cero dependencias nuevas, y un solo `@unchecked Sendable` nuevo
- [X] T080 [P] Actualizar `CLAUDE.md`: describir el motor único consolidado, la propiedad de `AVAudioSession` por `AudioSessionCoordinator`, el tap permanente, el estado suspendido de la sesión, y el formato de export por líneas alineadas. Retirar las descripciones de `ContinuousSpeechListener` y de la selección de motor por hardware, que dejan de ser ciertas
- [X] T081 [P] Rellenar `.specify/memory/constitution.md` con las reglas reales de `CLAUDE.md`. Hoy es la plantilla sin rellenar y no aporta ninguna puerta evaluable, como quedó declarado en `plan.md`
- [ ] T082 Retirar del repo `INFORME-DIAGNOSTICO-ASR.md` si `DIAGNOSIS_AUDIO_PIPELINE.md` lo deja obsoleto, **previa confirmación del usuario**

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: sin dependencias. T001 debe hacerse **antes** de tocar código: la línea base no se puede recuperar después
- **Foundational (Phase 2)**: depende de Setup. **BLOQUEA todas las historias**
- **US4 (Phase 3)**: depende de Foundational. Sin dependencias con otras historias
- **US1 (Phase 4)**: depende de Foundational. Instrumenta componentes creados allí
- **US3 (Phase 5)**: depende de Foundational. Se valida mucho mejor con US1 hecha
- **US2 (Phase 6)**: depende de Foundational. **T042 y T044 requieren la señal de rotación** del motor consolidado
- **US5 (Phase 7)**: depende de Foundational. Construye sobre `AudioSessionCoordinator`
- **US6 (Phase 8)**: depende de Foundational. **T059 requiere `RecognitionRequestBox`** (T014) y `AudioCaptureSession` (T015)
- **US7 (Phase 9)**: depende de Foundational. Es la más aislada: no toca la ruta de audio
- **Polish (Phase 10)**: depende de todas las anteriores

### Dependencias reales entre historias

- **US2 → US6**: ambas tocan el ciclo de rotación de `AppleSFSpeechEngine`. Si se hacen en paralelo, coordinar T042 con T059
- **US5 → US6**: ambas tocan `AudioCaptureSession`. T054 (`rebuildCapture`) y T059 (rotación sin tocar el tap) son las dos caras de research R4 y conviene revisarlas juntas
- **US1 → todas**: no es un bloqueo técnico, pero sin US1 las demás se validan a ojo. **Es la razón de que sea P1**
- **US4, US7**: sin dependencias con nadie. Son las candidatas naturales para trabajo en paralelo

### Parallel Opportunities

- Phase 2: T005, T006, T008, T010, T011 en paralelo (archivos distintos). T007 depende de T005 y T006; T012 de T010 y T011; T016 de T014 y T015
- Phase 4: T027, T028, T029, T030 en paralelo (cuatro archivos distintos)
- Phase 9: T066 y T067 en paralelo, antes de T068
- US4 y US7 pueden ir en paralelo con cualquier otra historia

---

## Parallel Example: Phase 2 Foundational

```bash
# Primer bloque — entidades y protocolos puros, sin dependencias entre sí:
Task: "T005 Crear TelemetryEvent en TranslatorApp/Domain/Entities/TelemetryEvent.swift"
Task: "T006 Crear PipelineTelemetryProtocol en TranslatorApp/Domain/Interfaces/"
Task: "T010 Crear AudioInterruptionReason en TranslatorApp/Domain/Entities/"
Task: "T011 Crear AudioSessionCoordinatorProtocol en TranslatorApp/Domain/Interfaces/"

# Después, las implementaciones de Data que dependen de ellos:
Task: "T007 Implementar PipelineTelemetry sobre OSLog"
Task: "T012 Implementar AudioSessionCoordinator"
```

---

## Implementation Strategy

### MVP — el corte más pequeño que entrega valor real

**Phase 1 + Phase 2 + Phase 3 (US4) + Phase 4 (US1)** — T001…T032.

- US4 arregla de golpe los cinco síntomas para los usuarios en A17 Pro+ con el modelo instalado, que hoy sufren el caso peor.
- US1 convierte el resto de síntomas en datos medibles.
- La Foundational, por sí sola, ya elimina los defectos divergentes de los motores duplicados.

**PARAR AQUÍ Y VALIDAR** contra `baseline.log` antes de seguir. Es el punto donde se comprueba si el diagnóstico de Fase 1 acertó.

### Entrega incremental

1. Setup + Foundational → un solo motor, telemetría viva
2. + US4 → cero dispositivos con el motor roto — **SC-019**
3. + US1 → diagnóstico en campo — **SC-026, SC-027, SC-028**
4. + US3 → las pausas traducen — **SC-014**
5. + US2 → el panel en vivo no se congela — **SC-016**
6. + US5 → alarmas y llamadas ya no matan la sesión — **SC-006, SC-007**
7. + US6 → cero palabras perdidas — **SC-004**
8. + US7 → export íntegro — **SC-020, SC-021**

### Riesgo abierto que conviene resolver antes de empezar la Phase 8

`plan.md` §Riesgos R1 y `research.md` §R6: con `IPHONEOS_DEPLOYMENT_TARGET = 26.1`, migrar a `SpeechAnalyzer` eliminaría la rotación de sesión y con ella **la razón de ser de toda la US6 y de la reconciliación de US2** (T041…T045, T059…T062: unas 11 tareas). El plan decidió no migrar en esta fase.

US1, US3, US5 y US7 son independientes del motor y se conservan íntegras pase lo que pase. Si esa decisión se reconsidera, el momento de menor coste es **antes de T041**.

---

## Notes

- `[P]` = archivos distintos, sin dependencias pendientes
- Cada tarea nombra el archivo exacto; las referencias `archivo:línea` apuntan al árbol actual, con los cambios sin commitear de 006 y 007 aplicados
- **No commitear sin que el usuario lo pida** (regla no negociable de `CLAUDE.md`)
- La línea base de T001 no se puede recuperar una vez modificado el código
- Los tres criterios que más fácilmente se dan por buenos sin comprobar de verdad: **SC-006** (hay que dejar sonar la alarma sin tocar el teléfono), **SC-004** (hay que comparar contra un texto de referencia) y **SC-020** (hay que contar las líneas)

**Total: 82 tareas.** US1: 9 · US2: 7 · US3: 7 · US4: 5 · US5: 12 · US6: 7 · US7: 11 · Setup: 4 · Foundational: 14 · Polish: 6
