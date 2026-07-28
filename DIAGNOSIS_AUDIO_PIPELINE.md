# Diagnóstico del pipeline de audio — Fase 1 (solo lectura)

**Fecha:** 2026-07-28
**Rama:** `007-preserve-conversation-history`
**Alcance:** lectura de código exclusivamente. Cero archivos de código modificados.
**Referencias:** todas las líneas citadas corresponden al árbol de trabajo actual (con los cambios sin commitear de las features 006 y 007 aplicados).

Abreviaturas de archivo usadas en las tablas:

| Alias | Ruta |
|---|---|
| `CSL` | `TranslatorApp/Data/ContinuousSpeechListener.swift` |
| `ASAE` | `TranslatorApp/Data/SpeechEngines/AppleSpeechAnalyzerEngine.swift` |
| `WKE` | `TranslatorApp/Data/SpeechEngines/WhisperKitEngine.swift` |
| `LSFE` | `TranslatorApp/Data/SpeechEngines/LegacySFSpeechEngine.swift` |
| `ARB` | `TranslatorApp/Data/Audio/AudioRingBuffer.swift` |
| `ESF` | `TranslatorApp/Data/Audio/EmptySegmentFilter.swift` |
| `REPO` | `TranslatorApp/Data/Respository/SpeechRepository.swift` |
| `TAUC` | `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift` |
| `NLP` | `TranslatorApp/Domain/Services/NLPSegmenterService.swift` |
| `QMS` | `TranslatorApp/Domain/Services/QualityMetricsService.swift` |
| `TVM` | `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` |
| `LTV` | `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` |
| `LTP` | `TranslatorApp/Presentation/Views/LiveTranscriptionPanes.swift` |
| `DC` | `TranslatorApp/App/DependencyContainer.swift` |
| `CR` | `TranslatorApp/Data/Models/ConversationRecord.swift` |
| `SCUC` | `TranslatorApp/Domain/UseCases/SaveConversationUseCase.swift` |
| `CDV` | `TranslatorApp/Presentation/Views/ConversationDetailView.swift` |

---

## Paso 0 — Mapa de arquitectura

### 0.1 El stack presunto es incorrecto

> Supuesto del usuario: *"posiblemente dos instancias de SFSpeechRecognizer más un Whisper local"*.

**El código lo contradice.** Existen tres implementaciones de motor, pero **se selecciona exactamente una por lanzamiento de la app, de forma exclusiva y sin posibilidad de coexistencia**, en `DC:52-66`:

```swift
// DC:52-66
let engine: any SpeechEngineProtocol
switch preference {
case .appleOnly:
    engine = AppleSpeechAnalyzerEngine()                       // DC:55
case .auto, .whisperPreferred:
    if DeviceCapabilities.supportsA17Pro && isWhisperInstalled {
        engine = WhisperKitEngine()                            // DC:59
    } else {
        engine = LegacySFSpeechEngine(listener: listener)      // DC:62
    }
}
```

Consecuencias exactas:

- **Nunca corren dos reconocedores a la vez.** No hay fan-out de audio a dos motores, ni contención de taps entre motores.
- `ContinuousSpeechListener` **se construye siempre** (`DC:42`), incluso cuando el motor elegido es `WhisperKitEngine` o `AppleSpeechAnalyzerEngine`. Su `AVAudioEngine` (`CSL:17`) y su `SFSpeechRecognizer` (`CSL:18`) quedan instanciados pero **nunca arrancados** en esos casos. De ahí la impresión de "dos SFSpeechRecognizer": existen dos *objetos*, solo uno se *usa*.
- `AppleSpeechAnalyzerEngine` es alcanzable **únicamente** con `preference == .appleOnly` (`DC:54`). Con `.auto` o `.whisperPreferred` y sin Whisper instalado se cae a `LegacySFSpeechEngine` (`DC:62`), no a `AppleSpeechAnalyzerEngine`. Es decir: `ASAE` y `CSL` son dos implementaciones casi idénticas y duplicadas de la misma lógica, y en la configuración por defecto (`.auto`) la que corre es `CSL`.
- **A pesar del nombre, `AppleSpeechAnalyzerEngine` NO usa `SpeechAnalyzer`/`SpeechTranscriber` de iOS 26.** Usa `SFSpeechRecognizer` (`ASAE:17,37,101`), como declara su propio encabezado (`ASAE:5-7`).

**Cuál de los tres motores está activo en el dispositivo del usuario determina qué síntomas puede sufrir.** Esto es lo primero que hay que confirmar en campo: la línea canónica ya existe en `DC:68` (`[Container] engine=<id>`).

### 0.2 Inventario de instancias

| Tipo | Nº de declaraciones | Archivo:línea | Quién la crea | Quién la destruye |
|---|---|---|---|---|
| `SFSpeechRecognizer` | 2 | `CSL:18`, `ASAE:17` | `CSL:18` (property init, eager); `ASAE:37` (en `start()`) | Nunca explícitamente; `ASAE` la reasigna en cada `start()` |
| `SFSpeechAudioBufferRecognitionRequest` | 2 propiedades | `CSL:15`, `ASAE:19` | `CSL:73`, `ASAE:75` — **recreada en cada rotación de sesión** | `CSL:181` / `CSL:272` (`endAudio()` + `= nil`), `ASAE:157` / `ASAE:164-166` |
| `SFSpeechRecognitionTask` | 2 propiedades | `CSL:16`, `ASAE:18` | `CSL:107`, `ASAE:101` | `CSL:180`/`CSL:273` (`cancel()`), `ASAE:156`/`ASAE:165` |
| `AVAudioEngine` | 3 | `CSL:17`, `ASAE:20`, `WKE:21` (asignado en `WKE:68`) | `CSL:17`/`ASAE:20` en property init (eager); `WKE:68` en `setupAudio()` | `CSL:270`, `ASAE:162`, `WKE:94-96` (`stop()` + `removeTap`) |
| Motor Whisper (`WhisperKit`) | 1 | `WKE:20` | `WKE:36` (`WhisperKit(WhisperKitConfig(model: "large-v3-turbo"))`) | **Nunca.** `WKE:54-63` (`stop()`) no libera `whisperKit`; el modelo queda residente |
| `AudioRingBuffer` | 2 | `CSL:35`, `ASAE:28` | property init | `reset()` en `CSL:263`, `ASAE:58` |
| `installTap(onBus: 0)` | 3 | `CSL:95` (buf 1024), `ASAE:94` (buf 1024), `WKE:80` (buf 4096) | mutuamente excluyentes | `removeTap` en `CSL:84,271`, `ASAE:85,163`, `WKE:79,95` |
| `AVAudioSession.setCategory` | 3 | `CSL:67` (`.record/.default/.duckOthers`), `ASAE:69` (idem), `WKE:71` (`.record/`**`.measurement`**`/.duckOthers`) | — | — |
| `AVAudioSession.setActive(true)` | 3 | `CSL:68`, `ASAE:70`, `WKE:72` | — | **`setActive(false)`: CERO ocurrencias en todo el repo** |
| Observador de interrupción | 1 | `DC:115-125` | `DC:113` `setupInterruptionObserver()` | **Nunca se remueve** |

### 0.3 Diagrama de flujo de audio

```
                         ┌─ RUTA SF (CSL o ASAE, exclusivas) ────────────────────────┐
 Micrófono
   │
   ▼
 AVAudioSession .record / .default / .duckOthers      [CSL:67 | ASAE:69]
   │  (setActive(true) — nunca setActive(false))      [CSL:68 | ASAE:70]
   ▼
 AVAudioEngine.inputNode                              [CSL:17 | ASAE:20]
   │  outputFormat(forBus:0) leído UNA vez            [CSL:83 | ASAE:84]
   ▼
 installTap(onBus:0, bufferSize:1024)                 [CSL:95 | ASAE:94]
   │  ── HILO DE RENDER DE AUDIO (tiempo real, QoS del sistema) ──
   ├──► request.append(buffer)                        [CSL:96 | ASAE:95]
   └──► ringBuffer.append(buffer)                     [CSL:97 | ASAE:96]
          └─ deepCopy(): AVAudioPCMBuffer(alloc) + memcpy + NSLock  [ARB:34-44, ARB:66-81]
             ⚠ ASIGNACIÓN DE MEMORIA Y LOCK EN EL HILO DE RENDER
   │
   ▼
 SFSpeechRecognitionTask callback (cola interna de Speech)   [CSL:107 | ASAE:101]
   │  Task { } → hop al actor                                [CSL:115 | ASAE:114]
   ▼
 continuation.yield(SpeechSegment)                     [CSL:222 | ASAE:137]

                         └───────────────────────────────────────────────────────────┘

                         ┌─ RUTA WHISPERKIT (exclusiva) ─────────────────────────────┐
 Micrófono → AVAudioSession .record / .measurement    [WKE:71]   ⚠ modo distinto
   ▼
 installTap(onBus:0, bufferSize:4096, fmt=16 kHz mono f32)  [WKE:75-84]
   │  ── hilo de render ──
   └──► Array(UnsafeBufferPointer(...)) → Task { await appendAudio(frames) }  [WKE:82-83]
   ▼
 audioBuffer: [Float]  ⚠ CRECE SIN LÍMITE                    [WKE:25, WKE:90]
   ▼
 transcriptionTask: bucle cada 2 s                           [WKE:102-116]
   │  chunk = audioBuffer COMPLETO (nunca recortado)          [WKE:107]
   ▼
 kit.transcribe(chunk)  →  yield(isHypothesis: true)         [WKE:128, WKE:150-152]
                         └───────────────────────────────────────────────────────────┘

 ── PIPELINE COMÚN, desde aquí ──────────────────────────────────────────────────────

 AsyncStream<SpeechSegment>
   ▼
 EmptySegmentFilter.filter  (actor + AsyncStream + Task)        [REPO:28 → ESF:21-45]
   ▼
 attachQualityRecording     (AsyncStream + Task)                [REPO:39-51]
   ▼
 TranscribeAudioUseCase pump: Task.detached SIN prioridad       [TAUC:41]
   │   ⚠ ninguna DispatchQueue con QoS explícito existe en todo el proyecto
   ├──► rawCont ──────────────────────────────────► uiTask @MainActor   [TVM:169-184]
   │                                                  └─► currentBuffer  [TVM:177,181,182]
   │                                                      └─► englishPane [LTP:44]
   │
   └──► segCont, saltando isHypothesis              [TAUC:48]
          ▼
        NLPSegmenterService (actor)                 [NLP:37-160]
          │ temporizador de estabilidad 0.7 / 1.2 / 2.5 s   [NLP:13-15, NLP:138-147]
          ▼
        AsyncStream<SegmentedPhrase>
          ▼
        for await phrase (MainActor)                [TVM:185-197]
          ├──► emittedPhrases.append                [TVM:193]
          └──► translationContinuation.yield        [TVM:190-191]
                 ▼
               .translationTask (serial, un await por iteración)  [LTV:115-165]
                 │ session.translate(...)                          [LTV:143]
                 ▼
               appendTranslation → translatedSentences             [TVM:215-233]
                 ▼
               spanishPane                                          [LTP:99-117]

 ── PERSISTENCIA ────────────────────────────────────────────────────────────────────
 saveConversation()                                              [TVM:134-150]
   │  englishText = emittedPhrases.joined(separator: " ")          [TVM:139]
   │  spanishText = translatedSentences.map(\.text).joined("\n")   [TVM:140]
   ▼
 SaveConversationUseCase  (guard solo sobre EN)                   [SCUC:26-29]
   ▼
 SwiftData ConversationRecord { englishText, spanishText, savedAt } [CR:11-14]
```

**QoS: dato relevante — no existe ninguna cola explícita.** Cero `DispatchQueue` creadas en el proyecto. Todo el pipeline post-tap corre sobre actores y `Task` con prioridad heredada; `TAUC:41` usa `Task.detached` **sin especificar prioridad**, lo que la fija en `.medium` y la desliga de la prioridad del llamador. No hay `.userInitiated` ni `.userInteractive` en ninguna parte.

### 0.4 Máquina de estados del ciclo de vida de la sesión

```
                       ┌──────────┐
                       │   IDLE   │
                       └────┬─────┘
     RecordButton [LTV:81] → toggleRecording [TVM:110]
                            → startRecording [TVM:153]
                            → executeBoth [TAUC:33]
                            → repository.startTranscription [REPO:25]
                            → engine.start
                            ▼
                    ┌───────────────┐
              ┌────►│   ESCUCHANDO  │
              │     └───┬───┬───┬───┘
              │         │   │   │
              │   (a)   │   │   └── error != nil  [CSL:123 | ASAE:123]
              │  isFinal│   │        ⚠ el código/dominio del error NUNCA se lee ni se loguea
              │[CSL:123]│   │
              │         │   └────── watchdog 65 s  [CSL:143-151]  (SOLO en CSL, no en ASAE)
              │         │
              │         ▼
              │   restartRecognition [CSL:155] / scheduleRestart [ASAE:140]
              │     1. setupRecognition(): removeTap → drain → append carry-over → installTap
              │     2. oldTask.cancel(); oldRequest.endAudio()     [CSL:180-181 | ASAE:156-157]
              └─────────┘  (vuelve a ESCUCHANDO)
                        │
                        └── si setupRecognition LANZA:
                              CSL:173-177 → handleError() → finishStream() → stream termina → UI se entera
                              ASAE:151-154 → log + return   ⚠ SIN cerrar el stream, SIN task, SIN avisar a la UI
                                              → CONGELACIÓN SILENCIOSA PERMANENTE

  Terminaciones externas:
   • stopRecording() usuario           [TVM:208-213] → transcribeUseCase.stop() [TAUC:73]
   • restartListening() usuario        [TVM:112-124] → stop + sleep 300 ms + start(preservingSession:true)
   • AVAudioSession .began             [DC:115-125]  → handleAudioInterruption [TVM:126-131]
                                                      → translatorState = .permissionDenied + stopRecording()
   • AVAudioSession .ended             ── NO EXISTE MANEJADOR ──
   • routeChangeNotification           ── CERO OCURRENCIAS EN EL REPO ──
   • AVAudioEngineConfigurationChange  ── CERO OCURRENCIAS EN EL REPO ──
   • mediaServicesWereReset            ── CERO OCURRENCIAS EN EL REPO ──
   • app a segundo plano / scenePhase  ── CERO OCURRENCIAS; sin UIBackgroundModes en Info.plist ──
```

**Quién maneja `result.isFinal`:** `CSL:123-129` y `ASAE:123-127`. En ambos, `isFinal` **no cierra el stream**: dispara una rotación de sesión. Correcto para captura continua.

**Quién maneja el callback de `error`:** `CSL:123` y `ASAE:123`, y **solo comprueban `error != nil`**. Ni el dominio, ni el código, ni la descripción se leen, se loguean ni se ramifican. Un `kAFAssistantErrorDomain 203` (sin habla), un `1101` (fallo del servicio local), un `301` (cancelación) y un error de red producen **exactamente la misma reacción**. Esta es la ausencia de telemetría más importante del sistema.

---

## Paso 1 — Evaluación de hipótesis

### H1 — Muerte silenciosa de `SFSpeechRecognitionTask` → **NO CONCLUYENTE** (con una sub-rama CONFIRMADA)

**Lo que sí está mitigado.** Ambos motores SF reinician la sesión ante `isFinal` o `error`:

```swift
// CSL:123-129
if isFinal || error != nil {
    if await self.isFinished { /* stop del usuario */ }
    else { await self.restartRecognition() }
}
```
```swift
// ASAE:123-127
let needsRestart = isFinal || error != nil
let finished = await self.isFinished
if needsRestart && !finished { await self.scheduleRestart() }
```

Además `CSL:143-151` tiene un watchdog de 65 s que fuerza el reinicio si nada ocurre. Es decir: **el escenario clásico "el tap sigue alimentando un request muerto y nadie lo nota" está cubierto en la ruta `CSL`.**

**Por qué sigue siendo NO CONCLUYENTE:**

1. **El código de error nunca se inspecciona ni se registra** (`CSL:123`, `ASAE:123`). Es imposible confirmar o descartar desde los logs actuales si en campo se está recibiendo 203/216/1101/301 o algo distinto. **Dato que falta:** `(error as NSError).domain` y `.code` en cada terminación, más el contador de reinicios por minuto.
2. **`requiresOnDeviceRecognition` nunca se fija** (CERO ocurrencias en el repo). El valor por defecto es `false` → con red disponible, el reconocimiento es **basado en servidor**, que es precisamente el modo sujeto al límite de ~1 minuto de audio y a fallos de red. La condición que activa H1 está presente por omisión.
3. **`ASAE` no tiene watchdog.** Si su callback deja de llegar sin `isFinal` y sin `error` (caso típico tras un cambio de ruta de audio), nada lo recupera.

**Sub-rama CONFIRMADA (`ASAE:149-155`):**

```swift
do { try await configureAndStart() }
catch {
    logger.error("[AppleSpeech] restart failed: \(error)")
    isRestarting = false
    return                       // ⚠ no cierra continuation, no hay task, la UI no se entera
}
```

Si el reinicio falla en `ASAE`, la `continuation` sigue abierta (`ASAE:21`), `isFinished` sigue `false` (`ASAE:22`), no queda ninguna `recognitionTask` viva y **el `for await` del ViewModel queda suspendido para siempre**. La UI conserva `isRecording == true` y el último texto renderizado. Es una congelación silenciosa y permanente. `CSL:173-177` sí hace lo correcto (`handleError()` → `finishStream()`), por lo que esta rama solo aplica al modo `APPLE` forzado.

---

### H2 — Ventana ciega en el reinicio de sesión → **NO CONCLUYENTE** (mitigación presente, gap residual sin medir) + **una sub-rama CONFIRMADA**

**Lo que sí está mitigado.** Existe un ring buffer de 1,5 s (`CSL:35`, `ASAE:28`, implementación `ARB:20-62`) y el orden de rotación es correcto: **el request nuevo se levanta ANTES de cerrar el viejo**:

```swift
// CSL:169-181
let oldTask = recognitionTask
let oldRequest = recognitionRequest
try setupRecognition(sessionId: currentSessionId)   // instala el tap nuevo y reproduce el carry-over
oldTask?.cancel()                                   // solo DESPUÉS
oldRequest?.endAudio()
```

Esto responde afirmativamente a la pregunta de la hipótesis: sí hay solapamiento y sí hay buffer circular.

**Gap residual real, no medido.** Dentro de `setupRecognition` la secuencia es:

| Paso | Línea (CSL / ASAE) | ¿Se captura audio? |
|---|---|---|
| `inputNode.removeTap(onBus: 0)` | `CSL:84` / `ASAE:85` | **NO** — a partir de aquí ni el request ni el ring buffer reciben nada |
| `ringBuffer.drain()` | `CSL:88` / `ASAE:88` | NO |
| bucle `request.append(buffer)` sobre el carry-over | `CSL:89` / `ASAE:89` | NO |
| `inputNode.installTap(...)` | `CSL:95` / `ASAE:94` | **Sí, se reanuda** |

A 48 kHz con `bufferSize: 1024`, 1,5 s de carry-over son ~70 `AVAudioPCMBuffer`, cada uno alimentado individualmente al request en `CSL:89`. La duración total de esa ventana **no está instrumentada en ninguna parte**. **Dato que falta:** timestamp monotónico inmediatamente antes de `removeTap` y justo después de `installTap`, y timestamp del primer buffer recibido por el tap nuevo.

**Sub-rama CONFIRMADA — reinicio manual con 300 ms garantizados de pérdida:**

```swift
// TVM:117-123
await transcribeUseCase.stop()             // motor detenido, tap removido, ring buffer reseteado (CSL:263)
try? await Task.sleep(nanoseconds: 300_000_000)   // ⚠ 300 ms sin ningún consumidor de audio
startRecording(preservingSession: true)
```

El botón "Restart Listening" (`LTV:86`) descarta deterministamente 300 ms de audio, más el tiempo de arranque del motor. Aquí no hay ring buffer que valga: `stop()` lo vacía (`CSL:263`, `ASAE:58`).

---

### H3 — Contención por el tap del micrófono → **DESCARTADA** en su forma literal; **sub-hallazgo CONFIRMADO** sobre el hilo de render

**Descartada porque:**

- Solo un motor está activo (`DC:52-66`), y cada motor tiene su **propio** `AVAudioEngine` (`CSL:17`, `ASAE:20`, `WKE:68`). Los tres `installTap(onBus: 0)` (`CSL:95`, `ASAE:94`, `WKE:80`) son mutuamente excluyentes en el tiempo.
- Los tres llaman `removeTap(onBus: 0)` antes de instalar (`CSL:84`, `ASAE:85`, `WKE:79`), evitando el reemplazo silencioso.
- **No hay fan-out de `AVAudioPCMBuffer` hacia dos consumidores independientes.** En la ruta SF el mismo closure alimenta el request y el ring buffer (`CSL:96-97`), pero ambos pertenecen al mismo motor.
- **La inferencia de Whisper NO corre en el hilo de render.** `WKE:83` copia las muestras y salta al actor (`Task { await self?.appendAudio(frames) }`); `kit.transcribe` se ejecuta en `WKE:128`, dentro de `transcriptionTask` (`WKE:102`), completamente fuera del callback de audio.

**Sub-hallazgo CONFIRMADO (ruta SF).** El callback del tap ejecuta trabajo prohibido en un contexto de tiempo real:

```swift
// ARB:34-44 (llamado desde CSL:97 / ASAE:96, en el hilo de render)
func append(_ buffer: AVAudioPCMBuffer) {
    guard buffer.frameLength > 0, let copy = buffer.deepCopy() else { return }   // ⚠ deepCopy asigna memoria
    ...
    lock.lock(); defer { lock.unlock() }                                          // ⚠ toma un NSLock
```
```swift
// ARB:66-81
func deepCopy() -> AVAudioPCMBuffer? {
    guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity) else { ... }  // ⚠ malloc
    ...
    for ch in 0..<channels { memcpy(dst[ch], src[ch], frames * MemoryLayout<Float>.size) }
```

El comentario de `ARB:16-19` justifica explícitamente el uso del lock ("held only for O(1) list operations"), pero **no contempla la asignación de memoria de `AVAudioPCMBuffer(pcmFormat:frameCapacity:)`**, que ocurre *fuera* del lock pero *dentro* del hilo de render. Asignar memoria en un render callback puede bloquear de forma no acotada y produce exactamente los overruns/glitches que describe H3. Confianza media: el mecanismo es real, la magnitud no está medida. **Dato que falta:** delta de `AVAudioTime.sampleTime` entre buffers consecutivos del tap.

---

### H4 — Política de endpointing indefinida → **CONFIRMADA** (existe endpointing propio, pero se cancela a sí mismo)

**Sí existe detección de silencio propia, con estos umbrales:**

| Umbral | Valor | Línea |
|---|---|---|
| Estabilidad, normal | **700 ms** | `NLP:13` |
| Estabilidad, ASR de baja calidad | **1200 ms** | `NLP:14` |
| Estabilidad, frase gramaticalmente abierta | **2500 ms** | `NLP:15` |
| Flush forzado por antigüedad de pendiente | **6,0 s** | `NLP:18` |
| Ventana de supresión de segmentos vacíos | **500 ms** | `ESF:18` |

**El defecto confirmado.** El temporizador se cancela en `NLP:72`, **antes** de cuatro salidas anticipadas que no lo reprograman:

```swift
// NLP:72-78
stabilityTimer?.cancel()                                    // ← se cancela SIEMPRE, primero
let fullText = segment.text
if fullText == lastSeenFullText { continue }                // ← NLP:74 sale sin reprogramar
lastSeenFullText = fullText
let pending = pendingSuffix(of: fullText)
guard !pending.isEmpty else { continue }                    // ← NLP:78 sale sin reprogramar
```

Las otras dos salidas: `NLP:89` (rama de timeout) y `NLP:102` (`guard !tail.isEmpty`).

`NLP:74` es la crítica. `SFSpeechRecognizer` **reemite el mismo parcial repetidamente mientras el hablante calla** — es su comportamiento normal durante una pausa. Cada reemisión idéntica entra por `NLP:72`, **cancela el temporizador de estabilidad que estaba a punto de disparar la emisión**, y sale por `NLP:74` sin volver a armarlo. Mientras el reconocedor siga repitiendo el mismo texto, la frase pendiente **nunca se emite**, nunca llega a `translationRequests` (`TVM:190`) y nunca se traduce.

Esto es literalmente el síntoma S2: *"cuando el hablante hace una pausa, el segmento debería pasar a traducción y no lo hace"*.

**Agravantes:**

- `NLP:82` (`maxPendingInterval` de 6 s) es la única red de seguridad, pero **solo se evalúa cuando llega un segmento nuevo con sufijo pendiente no vacío**. Si el flujo entrante es una repetición idéntica, la condición nunca se comprueba. No hay temporizador independiente que la vigile.
- `isLikelyIncomplete` (`NLP:186-206`) devuelve `true` para **cualquier** cola de más de 2 palabras en la que `NLTagger` no detecte un verbo (`NLP:204`). En transcripción parcial, donde la cola suele ser un fragmento nominal, esto dispara constantemente el umbral lento de 2500 ms (`NLP:130-132`).
- `isLowQualitySpeech()` (`QMS:110-125`) marca baja calidad si `avgWordsPerSecond > 4.0` (`QMS:120`). **Un hablante rápido es clasificado como baja calidad**, lo que sube el umbral de 700 a 1200 ms (`NLP:133-134`) justo cuando más rápido debería emitir.

Confianza: **alta**.

---

### H5 — Interrupciones de `AVAudioSession` no manejadas → **CONFIRMADA**

Resultado del barrido exhaustivo sobre todo el repo (excluyendo `build/` y `xcuserdata/`):

| Elemento | Ocurrencias | Detalle |
|---|---|---|
| `AVAudioSession.interruptionNotification` | **1** | `DC:116`. Observer en `DC:113-127`. Solo maneja `.began` (`DC:120`). **No hay rama `.ended` ni lectura de `shouldResume`.** El observer nunca se remueve. |
| `routeChangeNotification` | **CERO** | — |
| `AVAudioEngineConfigurationChange` | **CERO** | — |
| `mediaServicesWereResetNotification` | **CERO** | — |
| `scenePhase` / `applicationDidEnterBackground` / `willResignActive` | **CERO** | — |
| `UIBackgroundModes` en `Info.plist` | **CERO** | `Info.plist` tiene 15 líneas: solo `CFBundleURLTypes`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`. No hay `.entitlements`. |
| `setActive(false)` | **CERO** | La sesión de audio nunca se desactiva |
| `setPreferredIOBufferDuration` | **CERO** | — |
| Categoría / modo | `.record`+`.default` en `CSL:67` y `ASAE:69`; `.record`+**`.measurement`** en `WKE:71` | Inconsistente entre motores |

**Consecuencias, una por una:**

1. **Interrupción (llamada, Siri, alarma):** se detecta `.began` → `handleAudioInterruption()` (`TVM:126-131`) pone `translatorState = .permissionDenied`, mensaje *"Microphone access was interrupted"*, `hasError = true` y `stopRecording()`. La grabación **muere y no se reanuda jamás**, y el usuario ve una alerta titulada **"Permission Required"** (`LTV:268`) que es factualmente falsa: no es un problema de permisos. No hay ninguna ruta que reanude tras `.ended`.
2. **Cambio de ruta (conectar/desconectar AirPods, auriculares, CarPlay):** sin manejador. El tap se instaló con el formato leído una sola vez en `CSL:83` / `ASAE:84`. Al cambiar la ruta, el `inputNode` adopta un formato distinto; el motor **deja de entregar buffers sin lanzar error y sin invocar el callback de reconocimiento**. En `CSL` el watchdog de 65 s (`CSL:143-151`) acabaría rescatándolo — con hasta 65 s de reunión perdida. En `ASAE` y en `WKE` **no hay watchdog: la congelación es permanente**. Este es el mecanismo más probable de S4.
3. **Reset de media services:** sin manejador. Requiere reconstruir todo el grafo de audio; la app no lo hace.
4. **Segundo plano / pantalla bloqueada:** sin `UIBackgroundModes` y sin observador de `scenePhase`, iOS suspende la captura. Nadie lo detecta ni lo reanuda ni lo informa. En una reunión larga, bloquear la pantalla equivale a perder el tramo.
5. **`.measurement` en WhisperKit vs `.default` en SF** (`WKE:71` vs `CSL:67`/`ASAE:69`): `.measurement` desactiva AGC y reducción de ruido — exactamente lo que los comentarios `CSL:65-66` y `ASAE:68` identifican como crítico para voz acentuada, distante o baja. La ruta WhisperKit contradice esa decisión.

Confianza: **alta**.

---

### H6 — Reconciliación de resultados parciales → **CONFIRMADA**

Hay reconciliación en el segmentador, **pero no en el ViewModel**, y esa asimetría rompe el panel EN en vivo tras la primera rotación del reconocedor.

**En el segmentador (correcto):** `pendingSuffix` detecta el reinicio del ASR y resetea su estado comprometido:

```swift
// NLP:217-222
let words = normalized.split(whereSeparator: \.isWhitespace)
if words.count <= committedWordCount {
    logger.info("[SEGMENTER] ASR restart detected ... — resetting")
    committedFullText = ""; committedWordCount = 0; pendingStartTime = nil
    return normalized
}
```

**En el ViewModel (roto):** no existe equivalente. `committedPrefix` se recalcula desde `emittedPhrases` **completo de toda la sesión**:

```swift
// TVM:248-253
private func refreshCommittedPrefix() {
    committedPrefix = emittedPhrases.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    committedWordCount = committedPrefix.isEmpty ? 0 : committedPrefix.split(...).count
}
```

y `emittedPhrases` **nunca se limpia dentro de una sesión** — es una decisión deliberada de la feature 007 (`TVM:154-157`, `TVM:67-69`).

La ruta caliente de los parciales es:

```swift
// TVM:174-182
let committed = self.committedPrefix
let full = segment.text.trimmingCharacters(in: .whitespaces)
if !committed.isEmpty, full.hasPrefix(committed) {
    self.currentBuffer = String(full.dropFirst(committed.count))...        // TVM:177
} else if !committed.isEmpty {
    let cw = self.committedWordCount
    let aw = full.split(whereSeparator: \.isWhitespace)
    self.currentBuffer = aw.count > cw ? aw.dropFirst(cw).joined(separator: " ") : ""   // TVM:181
} else { self.currentBuffer = full }
```

**Secuencia del fallo, paso a paso:**

1. Minuto 0-1: sesión SF nº 1. `full` contiene el texto acumulado de esa sesión, que **sí** empieza por `committedPrefix`. Rama `TVM:177`. Funciona.
2. Minuto ~1: rotación de sesión (`CSL:155` / `ASAE:140`). El nuevo `SFSpeechAudioBufferRecognitionRequest` (`CSL:73`) **empieza su transcripción desde cero**.
3. Ahora `full` = "So the next thing" (4 palabras) y `committedPrefix` = todo lo hablado en el minuto anterior (p. ej. 180 palabras). `full.hasPrefix(committed)` es **falso** → rama `TVM:178-181`.
4. `cw = 180`, `aw.count = 4` → `aw.count > cw` es **falso** → **`currentBuffer = ""`**.
5. Con cada nueva emisión, `emittedPhrases` sigue creciendo, luego `cw` sigue creciendo. Una sesión SF, limitada a ~60 s, **jamás volverá a superar el conteo acumulado de toda la reunión**.

**Resultado:** desde la primera rotación (~1 minuto de reunión) el panel EN en vivo se queda vacío o congelado en lo último renderizado, mientras el histórico gris (`LTP:34-40`) sigue mostrando las frases antiguas. Es exactamente S3: *"la transcripción se queda pegada mostrando una frase antigua"*.

Confianza: **alta**. Es determinista, no intermitente — pero el usuario lo percibe como intermitente porque depende de cuánto se haya hablado antes de la primera rotación.

---

### H7 — Backpressure en la traducción → **DESCARTADA** como causa de S1; **NO CONCLUYENTE** para S2; **sub-rama CONFIRMADA** para S5

**Descartada para S1 (pérdida de audio):**

- La traducción es **serial** (un `await session.translate` por iteración, `LTV:143`) pero corre en el closure de `.translationTask` (`LTV:115`), completamente desacoplada del pipeline de captura. Los motores son actores independientes; el callback del tap (`CSL:95`) no espera a nadie aguas abajo.
- **No hay cola acotada que descarte trabajo.** `TVM:162` usa `AsyncStream.makeStream(of:)` sin política de buffering → `.unbounded` por defecto. Lo mismo en `TAUC:38-39`, `REPO:40`, `ESF:22`, `NLP:38`. Ningún `AsyncStream` del pipeline descarta elementos por presión.
- Conclusión: la traducción puede acumular **latencia** sin cota, pero **no puede provocar pérdida de audio**.

**NO CONCLUYENTE para S2:** una latencia creciente produce el mismo síntoma percibido ("no traduce") que el defecto de H4, y hoy no se pueden distinguir. Ya existe instrumentación parcial: `[TRANSLATE-START id=…]` (`LTV:141`) y `[TRANSLATE-DONE id=… ms=…]` (`LTV:146`). **Dato que falta:** profundidad de cola instantánea (`emittedPhrases.count − translatedSentences.count`) emitida junto a cada evento.

**Sub-rama CONFIRMADA:** si `prepareTranslation()` falla, el closure hace `return` **antes de consumir un solo request**:

```swift
// LTV:122-131
do { try await session.prepareTranslation() }
catch {
    ... viewModel.translatorState = .modelUnavailable ...
    return                       // ⚠ el for-await de LTV:137 nunca se ejecuta
}
```

A partir de ahí el inglés sigue acumulándose en `emittedPhrases` (`TVM:193`) durante toda la reunión, mientras `translatedSentences` queda **permanentemente vacío**. El export resultante tiene inglés completo y `"(no translation)"` (`TVM:48`). Contribuye a S5.

---

### H8 — Modelo de datos del export → **CONFIRMADA**

**No existe entidad de segmento.** La unidad persistida es la sesión completa, aplanada a **dos `String` monolíticos**:

```swift
// CR:11-14
@Attribute(.unique) var id: UUID
var englishText: String
var spanishText: String
var savedAt: Date
```
```swift
// TVM:138-141
try await saveConversationUseCase.execute(
    englishText: emittedPhrases.joined(separator: " "),
    spanishText: translatedSentences.map(\.text).joined(separator: "\n")
)
```

| Requisito de la hipótesis | Estado | Evidencia |
|---|---|---|
| Origen y destino como campos separados | Sí, pero **a nivel de sesión, no de segmento** | `CR:12-13` |
| ¿El traducido sobrescribe al original? | **No.** Son campos distintos | `CR:12-13` |
| Timestamp por segmento | **CERO.** Solo `savedAt` por conversación entera | `CR:14`, asignado en `SCUC:34` |
| Etiqueta de idioma | **CERO.** El idioma está codificado en el *nombre del campo* | `CR:12-13` |
| Correspondencia 1:1 EN↔ES | **Imposible de reconstruir** | separadores distintos: `" "` para EN, `"\n"` para ES (`TVM:139-140`) |

**Qué queda guardado cuando la traducción falla:** el inglés queda; el español **no deja hueco, ni placeholder, ni marcador de error**.

```swift
// LTV:150-162
} catch {
    viewLogger.error("❌ [UI] Translation error: ...")
    // ⚠ nunca se llama appendTranslation → translatedSentences no crece
```

**Cuatro filtros asimétricos** que reducen `translatedSentences` sin tocar `emittedPhrases`:

| Filtro | Línea | Efecto |
|---|---|---|
| Frases de ≤2 caracteres descartadas antes de traducir | `LTV:138` | ES pierde una entrada |
| Error de traducción sin append | `LTV:150-162` | ES pierde una entrada |
| Traducción vacía tras trim | `TVM:217` | ES pierde una entrada |
| Dedup normalizado (case/diacríticos/puntuación) | `TVM:223-227` | **Más agresivo** que el dedup EN, que es igualdad exacta de string (`TVM:192`) |

El último es especialmente insidioso: dos frases EN que solo difieren en puntuación producen **2 entradas EN pero 1 sola entrada ES**.

**Sin guard simétrico en persistencia:**

```swift
// SCUC:26-29
let trimmedEN = englishText.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmedEN.isEmpty else { throw ConversationError.emptyTranscript }
// ⚠ no existe el guard equivalente para spanishText — se guarda "" sin avisar
```

**Además:** `stopRecording()` (`TVM:208-213`) cierra `translationContinuation` sin drenar las traducciones en vuelo. Cualquier `session.translate` pendiente cuando el usuario pulsa Stop se pierde. No hay lógica de timeout explícita en ningún punto del pipeline de traducción.

**Código de export duplicado** en dos sitios con formato idéntico: `TVM:45-49` (sesión viva) y `CDV:24-30` (desde el historial). Ambos emiten siempre las dos cabeceras, con placeholders `"(no transcript)"` / `"(no translation)"`. El export son **dos bloques separados**, no un intercalado por frase.

Confianza: **alta**.

---

### H9 (nueva) — `WhisperKitEngine` re-transcribe toda la sesión cada 2 segundos → **CONFIRMADA, crítica**

```swift
// WKE:102-116
transcriptionTask = Task {
    let windowFrames = Int(sampleRate * windowSizeSeconds)
    while isRunning && !Task.isCancelled {
        try? await Task.sleep(nanoseconds: UInt64(windowSizeSeconds * 1_000_000_000))
        guard isRunning && !Task.isCancelled else { break }
        let chunk = self.audioBuffer                     // ⚠ WKE:107 — TODO el buffer acumulado
        if chunk.count >= windowFrames / 4 { await transcribeChunk(chunk) }
    }
    if !audioBuffer.isEmpty { await transcribeChunk(audioBuffer, isFinalFlush: true) }
}
```
```swift
// WKE:89-91
private func appendAudio(_ frames: [Float]) {
    audioBuffer.append(contentsOf: frames)              // solo crece
}
```
```swift
// WKE:153
if isFinalFlush { audioBuffer = [] }                    // ⚠ único punto de vaciado
```

`isFinalFlush` solo es `true` en `WKE:114`, es decir **después de que el bucle termine**. Durante toda la sesión el buffer nunca se recorta.

**Consecuencia aritmética:** a los 60 s se transcriben 60 s de audio cada 2 s; a los 5 minutos, 300 s de audio cada 2 s; a los 30 minutos, 1800 s. El coste de inferencia de `large-v3-turbo` crece linealmente con la longitud del chunk mientras la cadencia se mantiene fija en 2 s. El bucle se retrasa sin cota, la ANE/CPU se satura y la app se vuelve no responsiva. Memoria: 16 kHz × 4 bytes = 64 KB/s → ~115 MB/30 min, solo del buffer crudo.

Explica **S1, S3 y S4** en la ruta WhisperKit. Confianza: **alta**.

---

### H10 (nueva) — Con WhisperKit, la traducción no se dispara nunca → **CONFIRMADA, crítica**

```swift
// WKE:144-151
let segment = SpeechSegment(text: rawText,
                            isFinal: isFinalFlush,
                            ...,
                            isHypothesis: !isFinalFlush)     // ⚠ true durante TODA la sesión
```
```swift
// TAUC:46-48
// Hypothesis segments (WhisperKit mid-window): skip segmenter entirely.
guard !segment.isHypothesis else { continue }                 // ⚠ nada llega a segCont
```
```swift
// NLP:65-68
if segment.isHypothesis { pendingHypothesis = segment; continue }   // segunda barrera
```

Como `isFinalFlush` solo es `true` en `WKE:114` (tras terminar el bucle), **todos** los segmentos emitidos durante la sesión llevan `isHypothesis: true`. Cadena de consecuencias:

1. `segCont` no recibe nada → `NLPSegmenterService` no emite ninguna `SegmentedPhrase`.
2. El `for await phrase in stableStream` (`TVM:185`) no itera nunca → `translationContinuation.yield` (`TVM:190`) no se ejecuta jamás → **cero traducciones**.
3. `emittedPhrases` (`TVM:193`) queda **vacío** durante toda la sesión.
4. `canSave` = `!isRecording && !emittedPhrases.isEmpty` (`TVM:43`) → **`false`** → `sessionActionsView` (`LTV:241`) **no renderiza los botones Save ni Export**.
5. El panel ES muestra permanentemente *"Waiting for translation..."* (`LTP:93-97`).
6. El panel EN sí muestra texto: `currentBuffer` viene del stream raw, y como `committedPrefix` está vacío se toma la rama `TVM:182` (`currentBuffer = full`) — mostrando el texto acumulativo completo que crece sin parar.

Explica **S2 y S5 completos** en la ruta WhisperKit. Precondición: dispositivo A17 Pro+ con modelo instalado (`DC:58`). Confianza: **alta**.

---

### H11 (nueva) — El watchdog se rearma solo en la rotación, no con la actividad → **CONFIRMADA, severidad menor**

`scheduleWatchdog()` se invoca **exclusivamente** desde `setupRecognition` (`CSL:103`), nunca desde `updateTranscript` (`CSL:187`). El comentario `CSL:140-142` asume que "una sesión sana siempre lo resetea antes de que dispare" — asunción válida **solo** si el reconocedor rota antes de 65 s. Si la sesión vive más (reconocimiento on-device, o silencio prolongado sin `isFinal`), el watchdog fuerza una rotación innecesaria cada 65 s, cada una con su gap de H2. Confianza: **media**.

---

### H12 (nueva) — Ausencia total de QoS explícito → **NO CONCLUYENTE**

Cero `DispatchQueue` en el proyecto. `TAUC:41` usa `Task.detached` **sin prioridad**, lo que fija `.medium` y desliga la tarea de la prioridad del llamador. Bajo presión de CPU (por ejemplo, la causada por H9) el pump que alimenta la UI compite en prioridad por defecto contra la inferencia. **Dato que falta:** latencia extremo-a-extremo desde el `yield` del motor hasta la asignación de `currentBuffer`, correlada con la carga de CPU.

---

## Paso 2 — Esperado vs. real

| Síntoma | Comportamiento esperado | Comportamiento real en el código | Hipótesis raíz | Archivo:línea | Confianza |
|---|---|---|---|---|---|
| **S1** — se pierden fragmentos con habla rápida | Ningún intervalo de audio queda sin consumidor; la velocidad del hablante no altera el pipeline | (a) En cada rotación, entre `removeTap` e `installTap` se ejecuta `drain()` + ~70 `append` con el micrófono desconectado; duración no medida. (b) El reinicio manual duerme 300 ms deterministas con el motor parado. (c) `deepCopy()` asigna memoria en el hilo de render. (d) Con WhisperKit, la inferencia se retrasa sin cota y el habla rápida agrava el desfase. (e) Hablar rápido (>4 palabras/s) es clasificado como "baja calidad" y **sube** el umbral de emisión de 700 a 1200 ms. **Corrección obvia:** mantener el ring buffer alimentado durante la ventana de swap y eliminar el `sleep(300ms)` | H2 + H3(sub) + H9 | `CSL:84-95`, `TVM:120`, `ARB:66-81`, `WKE:107`, `QMS:120` | **media** |
| **S2** — la pausa no dispara la traducción | Tras ~700 ms de silencio, la cola pendiente se emite y entra en la cola de traducción | `stabilityTimer?.cancel()` (`NLP:72`) se ejecuta **antes** de `if fullText == lastSeenFullText { continue }` (`NLP:74`). Cada reemisión idéntica del parcial —el comportamiento normal de SF durante una pausa— cancela el temporizador sin reprogramarlo. La red de seguridad de 6 s (`NLP:82`) solo se evalúa al llegar un segmento con pendiente no vacío, así que tampoco actúa. Con WhisperKit, además, ningún segmento llega jamás al segmentador. **Corrección obvia:** reprogramar el temporizador antes de cada `continue`, o armarlo desde un reloj independiente | H4 (+H10 en ruta Whisper) | `NLP:72-78`, `NLP:82`, `TAUC:48`, `WKE:150` | **alta** |
| **S3** — se queda pegada en una frase antigua | Tras cada rotación del reconocedor, el panel EN sigue mostrando la cola en vivo actual | `committedPrefix` acumula **toda** la sesión (`TVM:249`, sin limpieza intra-sesión por diseño de 007). Tras la primera rotación, el texto del request nuevo empieza en cero: `full.hasPrefix(committed)` falla y `aw.count > cw` es falso para siempre → `currentBuffer = ""` permanente (`TVM:181`). El segmentador **sí** detecta el reinicio (`NLP:217-222`); el ViewModel no tiene el equivalente. Ruta secundaria: si el reinicio de `ASAE` falla, la continuation queda abierta sin task y la UI congela el último frame (`ASAE:151-154`) | H6 (+H1 sub-rama) | `TVM:174-182`, `TVM:248-253`, `NLP:217-222`, `ASAE:151-154` | **alta** |
| **S4** — congelación total, hay que reiniciar la app | Cualquier interrupción, cambio de ruta o reset de servicios se detecta y se recupera en segundos | `routeChangeNotification`, `AVAudioEngineConfigurationChange` y `mediaServicesWereReset`: **CERO ocurrencias**. Conectar AirPods cambia el formato del `inputNode` (leído una sola vez en `CSL:83`/`ASAE:84`) y el motor deja de entregar buffers sin error. Solo `CSL` tiene watchdog (`CSL:143-151`) → hasta 65 s perdidos; `ASAE` y `WKE` no lo tienen → congelación permanente. La interrupción `.began` mata la sesión y muestra "Permission Required" (`LTV:268`), y **no hay rama `.ended`** que reanude. Sin `UIBackgroundModes` ni `scenePhase`, bloquear la pantalla suspende la captura sin aviso. Con WhisperKit, la saturación de H9 congela la app por sí sola. **Corrección obvia:** observar route change + configuration change y reinstalar el tap con el formato nuevo | H5 + H9 (+H1 sub-rama) | `DC:113-127`, `TVM:126-131`, `CSL:83`, `ASAE:84`, `WKE:107`, `Info.plist` (15 líneas, sin `UIBackgroundModes`) | **alta** |
| **S5** — el export no siempre trae ambos idiomas | Cada frase exportada lleva su original y su traducción, o una marca explícita de que falta | No existe entidad de segmento: se persisten dos `String` monolíticos (`CR:12-13`) unidos con separadores distintos (`" "` vs `"\n"`, `TVM:139-140`), sin timestamp por frase ni etiqueta de idioma. Cuatro filtros reducen ES sin tocar EN (`LTV:138`, `LTV:150`, `TVM:217`, `TVM:224`), el dedup ES es más agresivo que el EN (`TVM:223` vs `TVM:192`), y `SCUC:26-29` valida EN pero **no** ES. Si `prepareTranslation()` falla (`LTV:122-131`) no se traduce ni una frase en toda la sesión. Con WhisperKit no se traduce nunca y los botones ni aparecen (`TVM:43`, `LTV:241`). **Corrección obvia:** persistir pares `(id, en, es?, t)` y marcar explícitamente las traducciones faltantes | H8 + H7(sub) + H10 | `CR:12-13`, `TVM:139-140`, `SCUC:26-29`, `LTV:122-131`, `TVM:223-227` | **alta** |

**Sobre agrupación de causas.** Los cinco síntomas **no** comparten una única raíz, pero tampoco son cinco bugs independientes. Se agrupan así:

- **Núcleo A — rotación de sesión SF y su reconciliación:** S1 y S3 comparten la rotación como evento desencadenante (H2 y H6). Arreglar la reconciliación del ViewModel resuelve S3 sin tocar S1.
- **Núcleo B — endpointing:** S2 es un defecto aislado y puntual (`NLP:72` vs `NLP:74`).
- **Núcleo C — resiliencia de `AVAudioSession`:** S4 es su propia raíz (H5), independiente de A y B.
- **Núcleo D — modelo de datos:** S5 es su propia raíz (H8), independiente de todo lo demás.
- **Transversal — WhisperKit (H9+H10):** si el dispositivo del usuario está en la ruta WhisperKit, **un solo defecto reproduce S1, S2, S3, S4 y S5 simultáneamente**. Por eso el primer dato de campo debe ser la línea `[Container] engine=…` (`DC:68`).

---

## Paso 3 — Instrumentación propuesta (especificación, no implementación)

Todos los eventos usan `OSLog` con `subsystem = com.spanesso.TraslatorApp` y una categoría nueva `Telemetry`, con un `sessionId` (UUID de la sesión de grabación) y un `monotonicMs` (`DispatchTime.now().uptimeNanoseconds / 1_000_000`) en **todos** los registros. `monotonicMs` es obligatorio: `Date()` puede saltar por ajuste de reloj y los deltas son el dato central.

### 3.1 Ciclo de vida de la sesión de reconocimiento

| # | Archivo | Evento | Campos |
|---|---|---|---|
| I-01 | `CSL:59` / `ASAE:48` | `SESSION_START` | `sessionId`, `engineId`, `locale`, `requiresOnDeviceRecognition`, `monotonicMs` |
| I-02 | `CSL:123` / `ASAE:123` | `SESSION_END` — **el registro más importante que falta hoy** | `sessionId`, `reason` ∈ {`isFinal`,`error`,`userStop`,`watchdog`}, **`errorDomain`**, **`errorCode`**, `errorDescription`, `sessionDurationMs`, `restartIndex` |
| I-03 | `CSL:161` / `ASAE:145` | `RESTART_BEGIN` | `sessionId`, `restartIndex`, `trigger` ∈ {`isFinal`,`error`,`watchdog`,`manual`} |
| I-04 | `CSL:182` / `ASAE:158` | `RESTART_END` | `sessionId`, `restartIndex`, `outcome` ∈ {`ok`,`failed`}, `totalMs`, `carryOverBufferCount`, `carryOverDurationMs` |
| I-05 | `ASAE:151-154` | `RESTART_FAILED_FATAL` — hoy solo hay un `logger.error` sin señalar que el pipeline queda muerto | `sessionId`, `errorDomain`, `errorCode`, `continuationStillOpen: Bool` |
| I-06 | `CSL:148` | `WATCHDOG_FIRED` | `sessionId`, `msSinceLastTranscript`, `msSinceSessionStart` |

### 3.2 Continuidad del audio (gaps en ms)

| # | Archivo | Evento | Campos |
|---|---|---|---|
| I-07 | `CSL:95` / `ASAE:94` / `WKE:80` (dentro del closure del tap) | `AUDIO_GAP` — emitir **solo** cuando el delta supere 2× la duración nominal del buffer, para no inundar el log | `sessionId`, `gapMs` (delta de `AVAudioTime.sampleTime` entre buffers consecutivos, convertido a ms), `expectedMs`, `bufferFrames`, `sampleRate` |
| I-08 | `CSL:84` (justo antes) y `CSL:95` (justo después) / `ASAE:85`,`:94` | `TAP_SWAP` — **mide directamente la ventana ciega de H2** | `sessionId`, `restartIndex`, `blindWindowMs`, `carryOverBufferCount`, `carryOverAppendMs` |
| I-09 | `CSL:95` / `ASAE:94` | `TAP_FIRST_BUFFER_AFTER_SWAP` | `sessionId`, `restartIndex`, `msSinceInstallTap` |
| I-10 | `ARB:34` | `RINGBUFFER_STATE` — una vez por segundo, no por buffer | `bufferedMs`, `bufferCount`, `evictedSinceLast` |
| I-11 | `TVM:120` | `MANUAL_RESTART_GAP` | `sleepMs` (300 hoy), `engineStopMs`, `engineStartMs`, `totalBlindMs` |

### 3.3 Segmentación y endpointing

| # | Archivo | Evento | Campos |
|---|---|---|---|
| I-12 | `NLP:72` | `STABILITY_TIMER_CANCELLED` — **confirma o descarta H4 en una sola sesión de campo** | `sessionId`, `reason` ∈ {`newSegment`,`duplicateText`,`emptyPending`,`emptyTail`,`timeout`}, `rescheduled: Bool`, `pendingTailWords`, `pendingAgeMs` |
| I-13 | `NLP:138` | `STABILITY_TIMER_ARMED` | `delayMs` (700/1200/2500), `reason` ∈ {`normal`,`lowQuality`,`incomplete`}, `tailWords` |
| I-14 | `NLP:144` | `STABILITY_TIMER_FIRED` | `armedToFiredMs`, `tailWords`, `emitted: Bool` |
| I-15 | `NLP:82` | `PENDING_AGE` — una vez por segundo mientras haya pendiente | `pendingAgeMs`, `pendingWords`, `maxPendingIntervalMs` (6000 hoy) |
| I-16 | `NLP:219` | `ASR_RESTART_DETECTED` (ya existe como `logger.info`; falta estructurarlo) | `incomingWords`, `committedWords`, `committedCharsDiscarded` |
| I-17 | `TVM:176-181` | `UI_PREFIX_MISMATCH` — **confirma H6 directamente** | `branch` ∈ {`hasPrefix`,`wordCount`,`noCommitted`}, `committedWordCount`, `incomingWordCount`, `resultingBufferChars` |

### 3.4 Cola de traducción

| # | Archivo | Evento | Campos |
|---|---|---|---|
| I-18 | `TVM:190` | `TRANSLATE_ENQUEUE` | `phraseId` (nuevo, monotónico), `chars`, `queueDepth` = `emittedPhrases.count − translatedSentences.count` |
| I-19 | `LTV:141` | `TRANSLATE_START` (ya existe; añadir campos) | `phraseId`, `queueDepth`, `waitedMs` (desde el enqueue) |
| I-20 | `LTV:146` | `TRANSLATE_DONE` (ya existe con `ms`; añadir campos) | `phraseId`, `translateMs`, `endToEndMs`, `queueDepth` |
| I-21 | `LTV:150` | `TRANSLATE_FAILED` — hoy solo hay un `logger.error` sin `phraseId` | `phraseId`, `errorDescription`, `sourceChars` |
| I-22 | `LTV:138` | `TRANSLATE_SKIPPED_TOO_SHORT` | `phraseId`, `chars` |
| I-23 | `TVM:224` | `TRANSLATE_DEDUP_DROP` (existe como `[DEDUP-DROP]`; falta `phraseId`) | `phraseId`, `dedupKey` |
| I-24 | `TVM:134` | `EXPORT_ALIGNMENT` — al guardar/exportar | `enCount`, `esCount`, `missingCount`, `missingPhraseIds` |

### 3.5 Sesión de audio e interrupciones

| # | Archivo | Evento | Campos |
|---|---|---|---|
| I-25 | `DC:115` | `AUDIO_INTERRUPTION` — hoy solo se observa `.began` | `type` ∈ {`began`,`ended`}, `options` (`shouldResume`), `wasRecording`, `monotonicMs` |
| I-26 | **nuevo observador** (no existe) | `AUDIO_ROUTE_CHANGE` | `reason` (`AVAudioSessionRouteChangeReason` crudo), `previousInputName`, `newInputName`, `previousSampleRate`, `newSampleRate`, `previousChannelCount`, `newChannelCount` |
| I-27 | **nuevo observador** (no existe) | `AUDIO_ENGINE_CONFIG_CHANGE` | `engineIsRunning`, `inputFormatDescription`, `tapFormatDescription`, `formatsMatch: Bool` |
| I-28 | **nuevo observador** (no existe) | `MEDIA_SERVICES_RESET` | `wasRecording`, `sessionId` |
| I-29 | `CSL:67` / `ASAE:69` / `WKE:71` | `AUDIO_SESSION_CONFIGURED` | `category`, `mode`, `options`, `sampleRate` efectivo, `ioBufferDuration` efectivo, `inputNumberOfChannels` |
| I-30 | **nuevo** (`scenePhase`, no existe) | `SCENE_PHASE_CHANGE` | `phase` ∈ {`active`,`inactive`,`background`}, `wasRecording`, `engineIsRunning` |

### 3.6 Salud de WhisperKit (solo ruta `WKE`)

| # | Archivo | Evento | Campos |
|---|---|---|---|
| I-31 | `WKE:107` | `WHISPER_WINDOW` — **expone H9 en el primer minuto de uso** | `chunkFrames`, `chunkSeconds`, `bufferGrowthSinceLastWindow`, `loopLagMs` |
| I-32 | `WKE:128` | `WHISPER_INFERENCE` | `chunkSeconds`, `inferenceMs`, `realtimeFactor` = `inferenceMs / (chunkSeconds × 1000)`, `tokenCount` |
| I-33 | `WKE:152` | `WHISPER_YIELD` | `isHypothesis`, `isFinal`, `textChars`, `reachedSegmenter: Bool` |

---

## Paso 4 — Criterios de aceptación medibles para la Fase 2

Cada criterio es un check binario, con el evento de instrumentación del Paso 3 que lo verifica.

### CA-1 — Continuidad del audio durante la rotación de sesión

| Criterio | Umbral | Verifica |
|---|---|---|
| CA-1.1 | `blindWindowMs` ≤ **50 ms** en el **p99** de todas las rotaciones de una sesión de 30 min | I-08 |
| CA-1.2 | `AUDIO_GAP` con `gapMs` > 50: **0 eventos** en 30 min | I-07 |
| CA-1.3 | `MANUAL_RESTART_GAP.totalBlindMs` ≤ **50 ms** (hoy: ≥300 ms garantizados) | I-11 |
| CA-1.4 | WER = **0** sobre un guion leído conocido de 5 min que cruce al menos 4 rotaciones | comparación con texto de referencia |

**Justificación de los 50 ms.** Un fonema en inglés conversacional dura 80–100 ms; la palabra funcional más corta ronda los 150–200 ms. Un hueco por debajo de 50 ms es físicamente incapaz de borrar un fonema completo, luego no puede alterar el reconocimiento. El ring buffer actual de 1,5 s (`ARB:28`) ya cubre tres órdenes de magnitud más que eso; el objetivo no es ampliarlo sino **eliminar la ventana en la que ni el request ni el ring buffer están conectados** (`CSL:84-95`). CA-1.4 es el check de verdad terreno: los otros tres pueden pasar y aun así perderse palabras si el replay del carry-over está mal ordenado.

### CA-2 — Recuperación tras interrupciones

| Criterio | Umbral | Verifica |
|---|---|---|
| CA-2.1 | Interrupción (llamada / Siri): reanudación automática ≤ **2 000 ms** desde `.ended` con `shouldResume` | I-25 |
| CA-2.2 | Cambio de ruta (AirPods conectar/desconectar): tap reinstalado con el formato nuevo ≤ **1 000 ms** | I-26 + I-09 |
| CA-2.3 | `AVAudioEngineConfigurationChange`: `formatsMatch == true` ≤ **1 000 ms** tras el evento | I-27 |
| CA-2.4 | Ningún evento de interrupción produce `translatorState == .permissionDenied` salvo denegación real de permisos | I-25 + estado |
| CA-2.5 | En 30 min con 3 interrupciones inyectadas y 2 cambios de ruta: **0 reinicios manuales de la app** necesarios | operativo |
| CA-2.6 | Con la app en segundo plano, o bien la captura continúa, o bien el usuario recibe un aviso explícito ≤ **1 000 ms** | I-30 |

**Justificación de los 2 000 ms.** Una llamada rechazada o un "Hey Siri" duran típicamente 1–3 s; el hablante suele repetir la última frase tras la interrupción, de modo que reanudar en ≤2 s deja la pérdida dentro de lo que el contexto conversacional absorbe. Técnicamente, `setActive(true)` tras una interrupción resuelve en <500 ms en condiciones normales; 2 000 ms da un margen de 4× que admite un reintento completo sin desbordar el criterio.

**Justificación de los 1 000 ms para route change.** Cambiar de auriculares es un evento del que el usuario es plenamente consciente y para el que tolera un corte breve. Por encima de 1 s el corte se come una frase entera (≈2,5 palabras/s × 1 s), lo que ya es una pérdida de contenido, no un artefacto.

### CA-3 — Endpointing y disparo de la traducción

| Criterio | Umbral | Verifica |
|---|---|---|
| CA-3.1 | Tras **800 ms** de silencio acústico, el **100 %** de las colas pendientes no vacías han sido emitidas | I-14 + I-15 |
| CA-3.2 | `STABILITY_TIMER_CANCELLED` con `rescheduled == false` y `pendingTail` no vacío: **0 eventos** | I-12 |
| CA-3.3 | Ninguna cola pendiente sobrevive más de **3 000 ms** (techo duro; hoy son 6 000 ms y solo se evalúan de forma oportunista) | I-15 |
| CA-3.4 | En un guion con 20 pausas ≥1 s, se emiten **20** frases (ni 19 ni 21) | I-14 |
| CA-3.5 | El umbral no se degrada por velocidad del hablante: a >4 palabras/s el `delayMs` sigue siendo el normal | I-13 |

**Justificación de los 700–800 ms.** Las pausas intra-frase en habla espontánea inglesa se concentran en 200–500 ms; las pausas entre frases superan sistemáticamente los 700 ms. Bajar de 600 ms parte frases por la mitad y multiplica los fragmentos enviados a traducir; subir de 1 000 ms introduce una latencia perceptible en una traducción "en vivo". El valor actual de 700 ms (`NLP:13`) está bien elegido: **el criterio no es cambiarlo, es que se dispare siempre.** Los 800 ms de CA-3.1 son 700 ms de umbral más 100 ms de holgura de scheduling.

**Justificación de los 3 000 ms de techo duro.** Tres segundos es el límite superior de una pausa retórica larga en habla continua; más allá de eso, retener texto sin emitir ya no es "esperar a que termine la frase", es una pérdida. Los 6 000 ms actuales (`NLP:18`) doblan ese umbral y además no están garantizados.

### CA-4 — Integridad del export bilingüe

| Criterio | Umbral | Verifica |
|---|---|---|
| CA-4.1 | ≥ **98 %** de los segmentos exportados tienen texto en ambos idiomas | I-24 |
| CA-4.2 | El **100 %** del ≤2 % restante lleva un marcador explícito (p. ej. `[traducción no disponible]`), nunca un hueco silencioso | I-24 + I-21 |
| CA-4.3 | `enCount == esCount` en el registro persistido: **siempre** (con marcadores contando como entrada) | I-24 |
| CA-4.4 | Cada segmento persistido lleva `id`, `timestamp`, `sourceLang`, `targetLang` | inspección del esquema |
| CA-4.5 | Al pulsar Stop, las traducciones en vuelo se drenan con timeout de **3 000 ms** antes de habilitar Guardar | I-18..I-21 |
| CA-4.6 | Si `prepareTranslation()` falla, el usuario es informado **antes** de acumular más de **10 s** de transcripción sin traducir | I-21 |

**Justificación del 98 %.** El modelo de traducción de Apple falla legítimamente en algunos casos (fragmentos sin contexto, ruido transcrito como texto). Exigir el 100 % obligaría a enmascarar esos fallos con contenido inventado. El 98 % admite el fallo real y **el requisito duro es CA-4.2**: un hueco marcado es aceptable y auditable; un hueco invisible —que es exactamente lo que ocurre hoy en `LTV:150-162`— no lo es. CA-4.3 convierte la alineación en un invariante estructural en vez de una coincidencia.

**Justificación de los 3 000 ms de drenaje.** El p95 de `session.translate` para una frase corta on-device está en el orden de cientos de ms; 3 s permiten drenar 3–5 frases en vuelo sin que el botón Guardar se sienta bloqueado.

### CA-5 — Estabilidad sostenida (cubre H9 y la congelación)

| Criterio | Umbral | Verifica |
|---|---|---|
| CA-5.1 | Sesión de **30 min** ininterrumpida: **0** congelaciones, **0** reinicios manuales de la app | operativo |
| CA-5.2 | `WHISPER_INFERENCE.chunkSeconds` **constante** (± 10 %) a lo largo de la sesión — no creciente | I-31, I-32 |
| CA-5.3 | `realtimeFactor` ≤ **0,5** sostenido (inferencia ≤1 s por ventana de 2 s) | I-32 |
| CA-5.4 | Memoria residente estable ± **10 %** entre el minuto 5 y el minuto 30 | Instruments |
| CA-5.5 | `WATCHDOG_FIRED` por inactividad real: **0 eventos** en 30 min con habla continua | I-06 |
| CA-5.6 | `RESTART_FAILED_FATAL`: **0 eventos**; si ocurre, la UI debe reflejarlo en ≤ **1 000 ms** | I-05 |
| CA-5.7 | Ruta WhisperKit: `WHISPER_YIELD.reachedSegmenter == true` para al menos **1** segmento cada **5 s** | I-33 |

**Justificación del factor 0,5.** Para que una ventana de 2 s se procese sosteniblemente, la inferencia debe terminar en menos de 2 s; un margen de 2× (≤1 s) absorbe la variabilidad térmica y la contención con otras apps sin que el bucle acumule retraso. CA-5.2 es el check directo contra H9: si `chunkSeconds` crece, el buffer no se está recortando.

**Justificación de los 30 minutos.** Es la duración mínima de la reunión real que motiva la app, y es más de 30 rotaciones de sesión SF a ~60 s cada una — suficiente para que cualquier fuga acumulativa (memoria, retraso del bucle, desalineación de `committedPrefix`) se manifieste.

---

## Cumplimiento de las condiciones de alcance

- **Archivos de código modificados: cero.** No se ha editado ningún `.swift`, `.plist`, `.xcodeproj`, `.pbxproj` ni archivo de configuración.
- **Archivo nuevo creado: uno**, este mismo (`DIAGNOSIS_AUDIO_PIPELINE.md`).
- **Nota sobre el criterio "`git status` solo muestra el `.md` nuevo":** el árbol de trabajo **ya estaba sucio antes de iniciar este diagnóstico**, con las modificaciones sin commitear de las features `006-fix-asr-word-loss` y `007-preserve-conversation-history` (16 archivos modificados, más `specs/006-*`, `specs/007-*`, `AudioRingBuffer.swift` e `INFORME-DIAGNOSTICO-ASR.md` sin trackear). Este diagnóstico no añade ninguna modificación a esa lista; la única entrada nueva es este archivo. El criterio no puede cumplirse literalmente sin descartar trabajo previo del usuario, cosa que no se ha hecho.
- **No se ejecutó ningún build, test ni comando git que altere el árbol de trabajo.**
- **No se creó ninguna rama** ni se ejecutó el hook `before_specify` (`speckit.git.feature`) registrado en `.specify/extensions.yml`, por conflicto directo con las restricciones de este encargo.
