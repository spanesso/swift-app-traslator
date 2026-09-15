# Captura, reconocimiento de voz y diarización en el dispositivo

**Informe técnico de investigación y diagnóstico** · 2026-09-15 · rama `010-transcript-durability`
Solo investigación: no se ha modificado código ni instalado nada.

**Restricciones confirmadas por el usuario**

| Parámetro | Valor |
|---|---|
| Dispositivo mínimo | iPhone 12 (A14), además de los iPad compatibles con iOS 26.1 |
| Duración de reunión | Típica 30–60 min; máxima 2 h |
| Participantes | Variable, hasta 10 o más |
| Etiqueta de hablante | En vivo, con unos segundos de retraso |
| Privacidad | Todo en el dispositivo; solo se permite descargar modelos |

**Cómo leer este documento**

| Marca | Significado |
|---|---|
| **[C]** | Confirmado leyendo el código, con referencia `archivo:línea` (rutas relativas a `TranslatorApp/`) |
| **[C✔]** | Confirmado y además comprobado a mano durante la redacción del informe |
| **[V]** | Hecho verificado en documentación oficial, repositorio original o paper (sección 12) |
| **[I]** | Inferencia razonada, no verificada; se indica cómo medirla |
| **[H]** | Hipótesis que requiere una prueba en dispositivo |

---

## 1. Resumen ejecutivo

1. **El reconocedor no es el primer culpable: el pipeline de la app pierde texto por sí mismo.**
   Hay pérdidas confirmadas en código que ocurren con cualquier motor:
   - **Al detener la grabación:** se descarta la última frase pendiente.
   - **Frases repetidas:** una segunda aparición de "Okay." o "I agree." se descarta durante toda la reunión.
   - **Frases muy cortas:** una de una sola palabra seguida de otra frase se salta.
   - **Rotación del reconocedor:** cuando no se oye texto, solo se recupera 1,5 s de audio.
   - **Cambio de sesión de reconocimiento:** se pierde la cola de texto pendiente.

   Deben corregirse **antes** de cambiar de modelo. Si no, cualquier comparación de modelos queda contaminada.
2. **La telemetría actual no puede demostrar que no se pierde audio.**
   - `carryOverMs`/`carryOverBuffers` de `RESTART_END` y `formatsMatch` están fijados como constantes en el código.
   - `TAP_FIRST_BUFFER` se emite antes de que llegue ningún buffer.
   - No hay señal de "el tap dejó de entregar audio", ni observación de temperatura.
3. **La restricción "solo en el dispositivo" no está garantizada en código** (regla del usuario: nada de la conversación sale de la app, nunca; ver Anexo A). `requiresOnDeviceRecognition` toma el valor de `supportsOnDeviceRecognition`. Si el sistema devuelve `false`, la petición se envía a los servidores de Apple.
4. **Motor recomendado: `SpeechAnalyzer` + `SpeechTranscriber` (iOS 26),** con `DictationTranscriber` como respaldo y `SpeechDetector` como VAD.
   - Apple lo presenta para audio largo y lejano (reuniones), con el modelo **fuera de la memoria de la app**.
   - Da marcas de tiempo por tramo (`audioTimeRange`), imprescindibles para la diarización.
   - Permite eliminar la rotación de reconocedores, que es la raíz de varias pérdidas.
   - Hoy está "aplazado deliberadamente" en `CLAUDE.md`. Este informe recomienda reabrir esa decisión.
5. **No aplicar reducción de ruido antes del ASR.** La evidencia publicada indica que empeora la tasa de error en modelos robustos.
6. **La diarización local es viable, pero con expectativas honestas.**
   - Apple **no ofrece ninguna API de diarización** (iOS 26 ni 27).
   - Opción recomendada: **FluidAudio** (Apache-2.0, Core ML) con pyannote community-1 + WeSpeaker + VBx.
   - Con un solo iPhone sobre la mesa se espera un DER de **~15–30 % con 2–5 personas** y **35–45 % o peor con más de 5** [I].
   - "Hablante N" es una agrupación de voces dentro de una reunión, no una identidad.
7. **Estrategia en dos niveles para "unos segundos tarde, en vivo":**
   - **En vivo:** etiqueta provisional con ~10 s de retraso.
   - **Al detener:** una pasada definitiva sobre el audio guardado, que corrige etiquetas y mantiene la numeración estable.
   - Esto obliga a **guardar el audio de la reunión en disco**, algo que hoy no se hace. Es una decisión de privacidad que debes aprobar.
8. **Orden recomendado:**
   1. Fase 0: medir.
   2. Fase 1: corregir las pérdidas del pipeline y guardar el audio.
   3. Fase 2: migrar a `SpeechTranscriber`.
   4. Fase 3: diarización al detener.
   5. Fase 4: diarización provisional en vivo.
   6. Fase 5 (opcional, A15+ o iPad): refinamiento con un segundo modelo.

---

## 2. Diagnóstico de la implementación actual

### 2.1 AVAudioSession

| Aspecto | Valor actual | Ref. |
|---|---|---|
| Categoría / modo / opciones | `.record` / `.default` / `.duckOthers` | [C] `Data/Audio/AudioSessionCoordinator.swift:78` |
| Activación | `setActive(true, .notifyOthersOnDeactivation)` al iniciar y en cada reanudación. Si la reactivación la hace el sondeo periódico, no se vuelve a llamar a `setCategory`. | [C] `:79`, `+Observation.swift:137` |
| Frecuencia preferida / tamaño de buffer IO | **No se configuran** | [C] grep |
| Voice processing (AEC/AGC/NS) | **No** | [C] grep |
| Bluetooth como entrada | **No** (no hay `.allowBluetooth` ni `.bluetoothHighQualityRecording`) | [C] |
| Micrófono y patrón polar | Elige el primer `.builtInMic` y el primer data source que admita `.omnidirectional`. Todo con `try?`, sin telemetría. | [C] `AudioSessionCoordinator.swift:106-137` |
| Segundo plano | `UIBackgroundModes = audio` | [C] `Info.plist:13-16` |
| Temperatura / memoria | No se observan `thermalState` ni avisos de memoria | [C] grep |

### 2.2 Captura y almacenamiento de audio

- **Motor y tap:** un `AVAudioEngine`, con `installTap(bufferSize: 1024, format: inputNode.outputFormat(forBus: 0))` [C] `Data/Audio/AudioCaptureSession.swift:146,162`.
  - Formato de hardware, sin `AVAudioConverter`.
  - [I] Normalmente 48 kHz, Float32, mono. iOS suele entregar buffers mayores de 1024 frames.
- **Qué hace el tap con cada buffer** [C] `:164-192`:
  1. Lo añade a la petición activa, bajo un lock (`RecognitionRequestBox`).
  2. Lo copia al buffer circular.
  3. Calcula el nivel RMS (solo el canal 0).
  4. Detecta huecos entre buffers.
- **Buffer circular:** ~1,5 s preasignado [C] `App/DependencyContainer.swift:61`, `Data/Audio/AudioRingBuffer.swift`.
- **Disco:** **el audio no se guarda en ninguna parte.** Solo se persiste el texto (journal) [C] grep.

### 2.3 Reconocimiento

- **Motor único:** `SFSpeechRecognizer` (`en-US`) con `SFSpeechAudioBufferRecognitionRequest` [C] `Data/SpeechEngines/AppleSFSpeechEngine.swift:154-170`.
  - `shouldReportPartialResults = true`, `taskHint = .dictation`, `addsPunctuation = true`.
  - `contextualStrings` solo si el usuario configuró términos.
- **On-device:** `request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition` [C✔] `:170, :267-269`. **Si el sistema devuelve `false`, el reconocimiento va al servidor.**
- **Rotación.** Se crea una nueva petición cuando ocurre cualquiera de estos eventos [C] `:242-262`, `+Rotation.swift:65-153`, `+Resilience.swift:66,83`:
  - un resultado `isFinal`;
  - cualquier error;
  - el watchdog de 65 s sin texto;
  - `RECOGNIZER_DEAF`: sin texto durante 4 s (luego 8 s y 16 s) mientras el medidor detecta energía de voz;
  - reanudación tras una interrupción;
  - cambio de ruta o de configuración.
- **Secuencia de rotación** [C] `AppleSFSpeechEngine.swift:175-210`, `+Rotation.swift:51`:
  1. Se vacía el buffer circular y se reinyecta en la nueva petición.
  2. Se hace el cambio de petición (swap).
  3. Se arranca la nueva tarea.
  4. Se llama a `endAudio()` en la anterior.
  5. **Se cancela** la tarea anterior de inmediato.
- WhisperKit está enlazado por SPM (rama `main`, sin versión fija), pero **no se usa** [C].
- `FoundationModelsCorrector` solo actúa sobre resultados finales en A17 Pro o posterior. **En la práctica está inactivo,** porque `isFinal` casi nunca llega [C].

### 2.4 Inicio y fin de voz (VAD)

- **No hay VAD acústico** [C]. `EmptySegmentFilter` filtra texto vacío y se llamaba `VADGate`.
- `AudioLevelMonitor` es un medidor RMS [C] `Data/Audio/AudioLevelMonitor.swift:42-85`:
  - umbral de voz **−45 dBFS**;
  - suelo de −60 dBFS;
  - retención de 1,5 s.

  Solo lo usan la interfaz y el watchdog `RECOGNIZER_DEAF`.
- [I] Con ruido de sala por encima de −45 dBFS el watchdog "cree" que hay voz. Con un hablante lejano por debajo de ese umbral, no lo detecta.

### 2.5 Segmentación y finalización de frases

Toda la segmentación se basa en **texto y temporizadores**, no en audio [C] `Domain/Services/NLPSegmenterService*.swift`.

| Regla | Constante | Ref. |
|---|---|---|
| Emisión por estabilidad | 0,7 s normal / 1,2 s calidad baja / 2,5 s si termina en preposición o conjunción | [C] `NLPSegmenterService.swift:15-17` |
| Techo de cola pendiente | 3 s | [C] `:26` |
| Corte de frase larga | >15 palabras, en `, ; : —` o `and/but/so/because…` | [C] `:18`, `:236-244` |
| Mínimo para emitir | 2 palabras (salvo emisión forzada) | [C] `:19`, `+Timing.swift:154` |
| Punto en resultado parcial | Emite si la cola tiene ≥3 palabras | [C] `:22` |
| Reinicio silencioso del reconocedor | El texto cae a ≤ la mitad (con ≥4 palabras previas) | [C] `:63-68` |
| Anclaje del texto confirmado | Busca anclas de 12 a 1 palabra en una ventana de 200 palabras; reinicia tras 3 fallos | [C] `+Text.swift:25-55` |

### 2.6 Resultados parciales y definitivos

- **Flujo** [C] `Domain/UseCases/TranscribeAudioUseCase.swift:38-61`. El motor produce un `AsyncStream`, y una tarea detached lo duplica en dos:
  - flujo *raw* → `LiveTailReconciler` → texto verde en vivo;
  - flujo del segmentador → `commitPhrase` → fragmento, journal y traducción.
- **Buffering:** todos los `AsyncStream` usan buffering **ilimitado**, así que ningún elemento se descarta por contrapresión [C]. El texto solo se descarta en filtros explícitos.
- **Orden:** cada callback del reconocedor crea su propia `Task` [C] `AppleSFSpeechEngine.swift:193`. [I] El orden FIFO de parciales no está garantizado.
- **Paso por el hilo principal:** `SpeechRepository` y `TranscribeAudioUseCase` heredan `MainActor` por la isolation por defecto. [I] Cada parcial pasa por el hilo principal, así que un hilo principal ocupado retrasa los temporizadores de estabilidad.

### 2.7 Pausas, interrupciones, llamadas, alarmas, cambios de micrófono

- **Interrupción:** estado `suspended`. Se detiene el engine, se quita el tap y se **vacía el buffer circular**; la sesión de audio sigue activa [C] `+Resilience.swift:47-53`, `AudioCaptureSession.swift:68-79`.
  - **El audio durante la interrupción no se captura**, por diseño.
  - Reanudación: notificación de fin o sondeo cada 2 s, con renuncia a los 60 s [C].
- **Cambio de ruta** [C] `+Observation.swift:59-94`, `AudioCaptureSession.swift:108-132`:
  - Solo `newDeviceAvailable` y `oldDeviceUnavailable` provocan reconstruir el tap con el formato nuevo y rotar.
  - Los eventos en los 800 ms posteriores a la propia activación se ignoran.
- **Media services reset:** no se recrea el `AVAudioEngine` ni se reconfigura la categoría [C] `+Observation.swift:111-116`.

### 2.8 Buffers durante transcripción, traducción y guardado

- La captura nunca espera a la traducción ni al guardado: son colas distintas [C].
- **Traducción:** serie FIFO sin timeout por petición. Una traducción colgada bloquea las siguientes, aunque un watchdog de 10 s lo reporta [C] `LiveTranscriptionView+Translation.swift:49`, `+Fragments.swift:118-153`.
- **Journal:** una línea JSON por frase y por traducción, con `synchronize()` en cada escritura. No guarda audio, marcas de tiempo por palabra ni hablante [C] `Data/Persistence/FileTranscriptJournal.swift:103-108`.

---

## 3. Causas probables de los fragmentos perdidos

Ordenadas por impacto estimado. Las marcadas [C✔] se comprobaron a mano.

### 3.1 Pérdidas en la lógica de la app (independientes del modelo)

| # | Causa | Mecanismo | Ref. | Impacto |
|---|---|---|---|---|
| P1 | **Última frase perdida al detener** | `stopRecording` cancela `transcriptionTask` (el consumidor del flujo del segmentador) **antes** de `transcribeUseCase.stop()`. El `flushTrailing` del segmentador emite a un flujo que ya nadie lee. Además, el engine llama a `continuation.finish()` antes de `endAudio()`, así que el último parcial tampoco llega. Lo mismo pasa en `restartListening`. | [C✔] `Presentation/ViewModels/TranscriptionViewModel+Session.swift:119-122`; `NLPSegmenterService.swift:82`; `AppleSFSpeechEngine.swift:138-140` | **Alto**: afecta a todas las reuniones |
| P2 | **Frases repetidas descartadas toda la reunión** | `fragmentKeys` es un `Set` que dura toda la sesión. Un segundo "Okay." o "Thank you." en cualquier momento se descarta antes del journal. | [C✔] `+Fragments.swift:29-33`, `TranscriptionViewModel.swift:106` | **Alto** en reuniones reales |
| P3 | **Rotación por "reconocedor sordo" recupera solo 1,5 s** | Tras 4 s sin texto (8 s y 16 s en reintentos) se cancela la tarea y solo se reinyecta 1,5 s. [I] Se pierde lo que la tarea anterior oyó y no emitió (≈2,5 s, 6,5 s o 14,5 s por rotación). | [C] `+Rotation.swift:51,112`; ring 1,5 s | **Alto** cuando ocurre |
| P4 | **Cola pendiente perdida en cada rotación** | Un cambio de `sessionGeneration` reinicia la línea base **sin vaciar** la cola pendiente; el temporizador armado ya no coincide y no emite. | [C✔] `NLPSegmenterService.swift:144-152`; `+Timing.swift:87` | Medio |
| P5 | **Frase de 1 palabra seguida de otra** | "Yes. I agree with that." → "Yes." no llega a 2 palabras y no se emite ni avanza; "I agree with that." sí se confirma y el ancla queda después: "Yes." se salta. | [C✔] `+Timing.swift:154`; `NLPSegmenterService.swift:205-211` | Medio (turnos cortos) |
| P6 | **Resto de 1 palabra sin techo** | Tras un corte por frase o cláusula, se cancelan ambos temporizadores y solo se rearma el de estabilidad; un resto de una palabra no se emite nunca. | [C] `+Timing.swift:170-174,200-203` | Bajo–medio |
| P7 | **Reinicio silencioso tras un enunciado corto** | La detección de reinicio exige ≥4 palabras previas; una cola de 2–3 palabras es sustituida por el nuevo hablante. | [C] `NLPSegmenterService.swift:65` | Medio en cambios de hablante |
| P8 | **Anclas cortas saltan palabras** | Si se reescribe una de las últimas 12 palabras, un ancla corta ("the meeting") puede casar con una repetición posterior y saltarse lo intermedio. | [C] `+Text.swift:25-55` | Bajo–medio |
| P9 | **Mezcla de journals** | Si queda un journal anterior, `beginSession` lanza error, pero `record()` reabre el **mismo archivo** y añade; ambas reuniones numeran desde 0 y la recuperación mezcla frases. | [C✔] `FileTranscriptJournal.swift:66-75, 97-99, 115-133` | Bajo en frecuencia, **grave** en efecto |

**Duplicados (también dañan la percepción de "no escucha bien"):**

| # | Causa | Ref. |
|---|---|---|
| D1 | Revisión de la última palabra confirmada: tras 3 fallos de ancla se reemite hasta 200 palabras | [C] `+Text.swift:45-51` |
| D2 | Con >400 palabras en la misma sesión de reconocimiento basta **un** fallo para reemitir | [C] |
| D3 | La rotación borra `committedTailWords` y el audio reinyectado se muestra dos veces | [C] `NLPSegmenterService.swift:151` |
| D4 | El corrector reconstruye `SpeechSegment` sin `sessionGeneration` (vale 0) y parece una rotación | [C] `Data/Correctors/FoundationModelsCorrector.swift:46-50` |

### 3.2 Pérdidas en la captura

| # | Causa | Ref. | Impacto |
|---|---|---|---|
| A1 | **Posible reconocimiento en servidor** (límite de ~1 min, errores de red, violación de privacidad) | [C✔] `AppleSFSpeechEngine.swift:170,267` | Alto (restricción) |
| A2 | **Buffer circular inerte tras un cambio de formato**: `formatsMatch` falla para siempre y descarta buffers mayores que el primero | [C] `AudioRingBuffer.swift:65-72,115-121,168` | Medio tras AirPods o cable |
| A3 | **Media services reset** sin recrear el engine: el tap puede "arrancar" sin entregar buffers, y ni `RECOGNIZER_DEAF` (sin energía) ni `AUDIO_GAP` (necesita un buffer siguiente) lo detectan | [C] `+Observation.swift:111-116`; `AudioCaptureSession.swift:204` | Medio [I] |
| A4 | Cambio real de ruta o configuración en los 800 ms posteriores a la activación: se ignora | [C] `+Observation.swift:59,68,83` | Bajo–medio |
| A5 | Carrera entre `drain()` y `swap()` en la rotación | [C] `AppleSFSpeechEngine.swift:175-178` | Bajo |
| A6 | Audio durante una interrupción (llamada, alarma): no se captura | [C] | Esperado, por diseño |

### 3.3 Factores acústicos y del modelo

| Factor | Estado | Evidencia |
|---|---|---|
| Distancia y volumen | [H] Contribuye. El modo `.default` aplica el procesado del sistema; no hay datos del patrón polar real del iPhone 12 | Medir con el protocolo de la sección 10 |
| Varios hablantes | [C] El reconocedor de iOS 26 **reinicia su transcripción sin avisar** en cambios de hablante (documentado en `CLAUDE.md`, 2026-08-05); P4 y P7 amplifican ese efecto | `SpeakerTurnTests` |
| Limitaciones del modelo | [V] `DictationTranscriber` usa "el mismo modelo que `SFSpeechRecognizer` on-device"; Apple posiciona `SpeechTranscriber` como el modelo nuevo para reuniones | WWDC25-277 |
| CPU, memoria, temperatura | [H] Sin datos: la app no registra `thermalState` ni memoria | Añadir telemetría (Fase 0) |
| Segundo plano | [C] El modo `audio` mantiene la captura; [I] no hay evidencia de pérdidas atribuibles | Medir |

**Conclusión del diagnóstico:** hay suficiente evidencia en código para atribuir una parte significativa de las pérdidas a P1–P9 y A1–A3. El reconocedor contribuye, pero **no puede evaluarse limpiamente hasta corregir el pipeline** y tener telemetría fiable.

---

## 4. Comparación de tecnologías y modelos

Métricas solo con fuente; "n/v" = no verificable, a medir en dispositivo. Los WER de benchmarks distintos **no son comparables entre sí**.

### 4.1 Reconocimiento de voz (ASR)

| Opción | Local | iOS mín. / A14 | Tiempo real | Precisión publicada | Latencia | Memoria / tamaño | Licencia | Integración | Ventajas | Riesgos |
|---|---|---|---|---|---|---|---|---|---|---|
| **Apple `SpeechTranscriber`** | Sí [V] | iOS 26. Comunidad: iPhone 12 sí, iPhone 11 no. **Comprobar `isAvailable`** [V] | Sí (volátil → final) | 14,0 % WER earnings22-10 % en M4 (Argmax, 2025-06) | n/v en iPhone | Modelo del sistema, **fuera de la memoria de la app** [V] | Apple | Baja–media | Pensado para reuniones y audio lejano; `audioTimeRange`; sin rotación; sin dependencias | Sin lista oficial de dispositivos; modelo no ajustable; sin cifras en iPhone |
| Apple `DictationTranscriber` | Sí | iOS 26, mismos dispositivos que SFSpeech on-device | Sí | n/v | n/v | Sistema | Apple | Baja | Respaldo con la misma API | Mismo modelo que hoy |
| `SFSpeechRecognizer` (actual) | Sí si `requiresOnDeviceRecognition` | iOS 13+ | Sí | n/v | n/v | Sistema | Apple | — | Ya integrado | Rotaciones, reinicios silenciosos, sin marcas de tiempo absolutas |
| WhisperKit (Argmax OSS, v1.1.0, 2026-08-06) | Sí (Core ML/ANE) | iOS 16. **A14: solo tiny/base/small** [V] | Sí (LocalAgreement) | small.en 12,8 % earnings22-10 % (M4) | Hipótesis 0,45 s / confirmado 1,7 s (M3 Max) | small: cientos de MB (n/v exacto) | MIT | Media | Streaming con confirmación; abierto | En A14 no mejora claramente a SpeechTranscriber; en la app la RAM la paga la app |
| whisper.cpp (v1.9.4, 2026-09-11) | Sí (Metal + Core ML) | Ejemplos iOS | Solo ejemplo de escritorio | = Whisper | n/v | tiny 273 MB … large 3,9 GB | MIT | Alta (C/C++) | VAD Silero integrado | Streaming propio a construir |
| Parakeet TDT 0.6B v2 vía FluidAudio | Sí (Core ML) | iOS 17; **A14 n/v**; int8 falla en A16 → fp16 | Por lotes | 6,05 % Open ASR; **AMI 11,16 %** [V] | Arranque en frío 4,4 s (iPhone 13) | ~600 MB | Apache-2.0 + CC-BY-4.0 | Media | Mejor precisión publicada en reuniones | Memoria en 4 GB; temperatura en 2 h |
| Parakeet EOU 120M (FluidAudio) | Sí | iOS 17; A14 n/v | Sí (chunks de 160/320 ms) | 4,87 % LibriSpeech clean (M2) | 320 ms de chunk | 120M parámetros | **NVIDIA Open Model License** | Media | Streaming ligero | Licencia a revisar; sin datos de reuniones |
| Moonshine v2 (2026-02) | Declarado | iOS (README); A14 n/v | Sí | 6,65–12,01 % Open ASR | 50–258 ms en M3 | 34–245M parámetros | MIT (inglés) | Media | Pensado para edge | Proyecto joven |
| sherpa-onnx zipformer | Sí | iOS, API Swift | Sí | No publicado | n/v | 68–180 MB int8 | Apache-2.0 | Media–alta | Maduro, ONNX | Modelos de 2023 |
| Argmax Pro SDK | Sí | n/v | Sí (160 ms) | Parakeet v2 11,7 % (M4) | 160 ms | n/v | Comercial; **renovación de licencia online cada 30 días** | Media | Diarización incluida | **Tráfico saliente periódico**: choca con la regla on-device |

### 4.2 VAD

| Opción | Local | Frame / latencia | Tamaño | Licencia | Veredicto |
|---|---|---|---|---|---|
| **Apple `SpeechDetector`** | Sí | n/v | Sistema | Apple | **Recomendado** con SpeechTranscriber; **no funciona sin un transcriber** [V] |
| **Silero VAD v6.2** | Sí (ONNX; Core ML en FluidAudio) | 30 ms, <1 ms por chunk en CPU [V] | ~2 MB | MIT | **Recomendado** como VAD independiente del ASR (watchdog, marcas de voz para diarización); v6.2 mejora voces apagadas |
| TEN VAD | Sí (arm64) | 10/16 ms | <1 MB | Apache + **cláusula de no competencia con Agora** | Descartado por licencia |
| pyannote segmentation-3.0 | Sí | Ventanas de 10 s | ~6 MB (n/v exacto) | MIT (descarga condicionada) | Útil dentro de la diarización, no como VAD de baja latencia |
| RMS actual (−45 dBFS) | Sí | 100 ms | — | — | Insuficiente: confunde ruido con voz |

### 4.3 Reducción de ruido y captura

| Opción | Veredicto | Evidencia |
|---|---|---|
| RNNoise / DeepFilterNet / DTLN | **No usar antes del ASR** | El autor de RNNoise lo desaconseja; arXiv 2512.17562 (40 configuraciones, todas peor WER); arXiv 2603.04710. DeepFilterNet y DTLN sin mantenimiento. |
| `setVoiceProcessingEnabled` | No por defecto; experimento A/B como mucho | Diseñado para VoIP; **efecto en WER n/v** |
| Modo `.measurement` | Candidato a A/B frente a `.default` | Minimiza el procesado del sistema; hoy el código lo evita a propósito ("keeps AGC + NR"). Hay que medir. |
| `AVInputPickerInteraction` (iOS 26) | **Recomendado** | Deja al usuario elegir micrófono y ver el nivel dentro de la app |
| `.bluetoothHighQualityRecording` (iOS 26) | **Recomendado** para usuarios con AirPods | [V] WWDC25-251 |
| Patrón polar | Consultar en tiempo de ejecución y registrarlo | Qué patrones expone cada modelo: n/v |

### 4.4 Diarización (resumen; detalle en la sección 5)

| Opción | Local | Tiempo real | Tope de hablantes | DER publicado | Licencia | Veredicto |
|---|---|---|---|---|---|---|
| API de Apple | — | — | — | **No existe** (verificado contra los símbolos oficiales de Speech, iOS 26/27) | — | ❌ |
| **FluidAudio offline** (community-1 + WeSpeaker + VBx) | Sí, iOS 17+ | No (80x tiempo real en iPhone 14 Pro) | Sin tope documentado | 10,6 % AMI SDM (arnés FluidAudio, Mac) | Apache-2.0 + CC-BY-4.0 | ✅ **Pasada definitiva** |
| FluidAudio streaming pyannote (chunks de 10 s) | Sí | ~10 s | Sin tope | 38,2 % AMI SDM (mismo arnés) | ídem | ⚠️ Solo provisional |
| FluidAudio LS-EEND | Sí | 100 ms | **10** (variante DIHARD) | 20,7 % AMI SDM | MIT (Core ML) | ⚠️ Provisional, si ≤10 hablantes |
| NVIDIA Streaming Sortformer v2/v2.1 | Sí (port Core ML) | 0,3–30 s | **4** | 20,57 % AMI SDM; 41,42 % DIHARD III ≥5 hablantes | CC-BY-4.0 / NVIDIA OML | ❌ Tope incompatible |
| Argmax SpeakerKit OSS | Sí, iOS 16+ | No | Clustering pyannote | "Comparable a pyannote" (SDBench) | MIT | ✅ Alternativa |
| sherpa-onnx | Sí | Offline | Clustering | 21,76 % AMI SDM (3D-Speaker) | Apache-2.0 | ⚠️ Más integración |
| pyannoteAI precision-2 | **No** (servidor, salvo Enterprise on-prem) | — | — | 12,9 % AMI IHM | Comercial | ❌ Regla on-device |

---

## 5. Viabilidad de la diarización local

### 5.1 Conceptos (qué promete y qué no)

| Término | Qué responde | Uso en esta app |
|---|---|---|
| **Diarización** | "¿Quién habló cuándo?", con etiquetas anónimas dentro de una grabación | **Sí**: "Hablante 1", "Hablante 2" |
| Identificación | "¿Esta voz es Ana?", contra voces registradas | **No**, salvo registro explícito con consentimiento |
| Verificación | "¿Esta voz es la de quien dice ser?" | No |

"Hablante N" es un **cluster de voz dentro de una reunión**. No identifica a una persona, no se reutiliza entre reuniones y puede equivocarse.

### 5.2 Cómo funciona (pipeline estándar)

1. **VAD / segmentación:** detecta voz y cambios de hablante. pyannote segmentation usa *powerset*: hasta 3 hablantes por ventana de 10 s y 2 simultáneos.
2. **Embeddings:** un vector por tramo (WeSpeaker ResNet34), que funciona como huella acústica.
3. **Clustering:** agrupa por similitud (AHC + VBx). **No necesita conocer el número de hablantes.**
4. **Reutilización del identificador:** si un embedding nuevo se parece a un centroide existente por encima de un umbral, recibe ese ID; si no, se crea uno nuevo.
5. **Diarización exclusiva:** un único hablante por instante, necesaria para asignar palabras del ASR.

### 5.3 Tiempo real frente a diferido

[V] En el mismo arnés, FluidAudio da 10,6 % de DER offline frente a 38,2 % en streaming por chunks. En el paper de diart, AMI pasa de 19,9 % offline a 27,5 % online con 5 s. **Casi toda la degradación es confusión de hablantes:** el clustering incremental decide con poca información. Argmax afirma que la diarización en tiempo real "no ha alcanzado calidad comercial".

→ **Diseño recomendado:** etiqueta provisional en vivo (~10 s) y **pasada definitiva al detener**, que corrige y renumera de forma estable (sección 6.6).

### 5.4 Precisión realista esperada [I]

Estimación para un solo iPhone sobre la mesa:

| Escenario | DER esperado |
|---|---|
| 2 personas, voces distintas, cerca del teléfono | ~10–20 % |
| 3–5 personas | ~15–30 % (lo más parecido publicado: AMI SDM 20–22 %) |
| >5 personas | 35–45 % o peor (Sortformer DIHARD III ≥5: 41,4 %) |

**Modos de fallo esperados:**
- voces parecidas (mismo sexo y edad) que se funden en un solo ID;
- alguien que se aleja del teléfono y aparece como hablante nuevo;
- "sí" u "ok" mal asignados;
- habla solapada;
- personas que casi no hablan, absorbidas por otro cluster.

### 5.5 Rendimiento en A14 [I]

- **Velocidad:** no hay benchmarks públicos en A14. FluidAudio publica 80x en iPhone 14 Pro. Estimando 20–50x en A14, la pasada de 2 h tardaría ~3–6 min en primer plano. **Hay que medirlo.**
- **Memoria:**
  - 2 h de audio a 16 kHz ocupan 230 MB (Int16) o 460 MB (Float32). **Debe leerse del disco por bloques.**
  - Clustering: con ~10.000 embeddings, una matriz de afinidad completa ocuparía ~800 MB. **Riesgo principal en 4 GB.** Si no cabe: clustering por bloques y fusión de centroides.

### 5.6 Privacidad y legal (no es asesoría jurídica)

- Los embeddings de voz pueden considerarse **datos biométricos**:
  - [V] RGPD art. 9;
  - [V] Ley 1581 de 2012, art. 5: datos sensibles;
  - [V] Illinois BIPA: "voiceprint".
- Con etiquetas anónimas limitadas a una reunión hay un argumento razonable de que no se busca "identificar unívocamente". Aun así, conviene:
  - **no persistir embeddings más allá de la reunión**: borrarlos al archivar, igual que el journal;
  - informar en la app de que se analiza la voz para separar hablantes;
  - dejar fuera del alcance el registro con nombre entre reuniones: exige consentimiento explícito de cada participante.

---

## 6. Arquitectura recomendada

Respeta `Data → Domain → Presentation` y el cableado en `DependencyContainer`. Todo lo nuevo entra detrás de protocolos de dominio.

### 6.1 Flujo

```
Micrófono
 → AVAudioSession (.record; modo .default, A/B con .measurement; picker de entrada; BT alta calidad)
 → AVAudioEngine, tap PERMANENTE (formato de hardware)
    ├─→ [continuo] AnalyzerInput → SpeechAnalyzer
    │       ├─ SpeechTranscriber (volatile + final + audioTimeRange)
    │       └─ SpeechDetector (VAD)
    ├─→ [continuo] MeetingAudioWriter: 16 kHz mono en bloques a disco (reloj de muestras absoluto)
    ├─→ [continuo] ring buffer (solo si hay reinicio de analizador) + nivel de entrada
    └─→ [diferido ~10 s, prioridad baja] LiveDiarizer (chunks desde el writer, no desde el tap)
 → Domain: TranscriptTimeline (frases con rango de audio absoluto)
 → NLPSegmenterService (frases estables; nunca une turnos de hablantes distintos)
 → SpeakerAssignment (puro): frase ↔ turnos de hablante por solape temporal
 → Journal (frase, traducción, asignación de hablante, checkpoint de diarización)
 → Traducción local (Translation, sin cambios)
 → Interfaz EN/ES con "Hablante N" (provisional atenuado / definitivo)
 → Al detener: FinalDiarizer sobre el archivo → remapeo estable → journal → archivo
```

### 6.2 Continuo frente a diferido

| Componente | Ejecución | Hilo |
|---|---|---|
| Tap, escritura del audio en el buffer de disco, VAD y ASR del sistema | Continuo | Tap: solo copias; ASR en proceso del sistema |
| Segmentador y journal de texto | Continuo, barato | Actores propios |
| Diarización provisional | Diferido (cada ~10 s), cancelable | `Task` detached `.utility`, desde el archivo |
| Diarización definitiva | Al detener, con progreso | `.userInitiated` en primer plano; [I] `BGContinuedProcessingTask` si el usuario sale |
| Refinamiento ASR con segundo modelo (opcional) | Al detener, solo A15+ o iPad | Igual que la anterior |

### 6.3 Que nada pesado bloquee la captura

- **El tap solo copia memoria:** a la entrada del analizador, a un buffer preasignado del escritor y al medidor. Nada de E/S de disco ni de ML en el tap.
- **Disco:** `MeetingAudioWriter` (actor) vacía bloques de ~1 s desde un buffer SPSC preasignado.
- **Diarización:** lee del **archivo**, nunca del tap. Si se retrasa, solo se retrasa la etiqueta.
- **Gobernador térmico:** en `.serious` se pausa la diarización provisional; en `.critical`, todo lo diferido. **La captura y el ASR nunca se pausan.**
- **Hilo principal:** sacar `SpeechRepository` y `TranscribeAudioUseCase` de `MainActor` (hoy lo heredan por defecto).

### 6.4 Conservar segundos antes y después de cada segmento

- **Audio completo:** con el audio en disco y un reloj de muestras absoluto, cada frase tiene un `CMTimeRange`. Cualquier proceso posterior lee `[inicio − 1,5 s, fin + 1,0 s]` directamente del archivo, sin depender de un ring buffer en RAM.
- **Ring buffer:** queda solo para reinyección en un reinicio del analizador, y corrigiendo A2 (cambio de formato).

### 6.5 Corregir frases parciales sin duplicar

- **Con `SpeechTranscriber`:** el texto **volátil** solo se muestra y nunca se confirma. Se confirma el texto **final** con su rango de audio.
- **Deduplicación por tiempo, no por texto:** una frase es la misma si su rango de audio se solapa más de un 50 % con otra ya confirmada. Esto resuelve P2 (repeticiones legítimas), D1–D3 y los reinicios silenciosos.
- **Correcciones posteriores (refinamiento, diarización):** se escriben como **nuevas entradas del journal** que referencian el `fragmentId`, nunca reescribiendo líneas. La línea visible cambia, pero la cuenta de líneas EN/ES se mantiene.

### 6.6 Identificador de hablante estable

- **Provisional:** numeración por **orden de aparición**. El centroide se actualiza con media móvil. Un ID nuevo requiere similitud por debajo del umbral en **dos chunks consecutivos** (histéresis), para no crear hablantes por un "ok".
- **Definitivo:** la pasada offline produce clusters sin nombre. Se asignan a los números provisionales con el **algoritmo húngaro**, maximizando el solape temporal. Así "Hablante 1" sigue siendo "Hablante 1" y solo cambian las frases mal asignadas.
- **Sin fusión automática** de dos IDs en vivo (lo haría la pasada final). Opcional: permitir al usuario renombrar o fusionar a mano.

### 6.7 Persistencia para recuperar una reunión interrumpida

- **Audio:** archivo por bloques (CAF/PCM Int16 16 kHz o AAC) con `.completeUntilFirstUserAuthentication`, igual que el journal. Un cierre abrupto solo daña el último bloque.
  - Tamaño: 2 h en PCM ≈ 230 MB; en AAC 32 kbps ≈ 29 MB.
- **Journal:** nuevas entradas independientes, cada una escrita una sola vez:
  - `speakerAssignment{fragmentId, speaker, provisional}`;
  - `diarizationCheckpoint{processedUntilSample, centroids}`.

  Los centroides son embeddings, así que se borran al archivar.
- **Al relanzar:** se recupera el texto como hoy, se reanuda la diarización desde el último checkpoint y se lanza la pasada final si no llegó a completarse.
- **Borrado:** tras archivar se elimina el audio (salvo que el usuario elija conservarlo), los centroides y el journal.

### 6.8 Dos personas hablando a la vez

- **Solape corto (<1 s):** la frase va al hablante con mayor tiempo (diarización exclusiva).
- **Solape largo:** se marca la frase como `Hablante 1 + Hablante 2` o "superpuesto" en lugar de adivinar.
- **Límite del ASR:** un micrófono y un reconocedor producen **una sola** transcripción del solape. Separar las dos voces (*speech separation*) no es viable con garantías en A14 y queda fuera del alcance.

---

## 7. Solución MVP de menor riesgo

Objetivo: dejar de perder texto y medir antes de cambiar de modelo. **Sin dependencias nuevas.**

1. **P1:** al detener, parar primero el motor (`endAudio` → esperar el último parcial) y dejar que el segmentador vacíe su cola en un consumidor **vivo**. Cancelar la tarea solo al final.
2. **P2:** limitar la deduplicación a una ventana corta (p. ej. la última frase o los últimos N segundos) en lugar de toda la reunión.
3. **P4:** vaciar la cola pendiente del segmentador **antes** de reiniciar la línea base en un cambio de `sessionGeneration`.
4. **P5 y P6:** emitir frases de una palabra completas ("Yes.", "Okay.") en la ruta de oraciones; armar siempre el techo tras un corte.
5. **P3:** ampliar el ring buffer para cubrir la ventana del watchdog `RECOGNIZER_DEAF` (≥ 4–5 s), o no cancelar la tarea anterior hasta que entregue su final.
6. **P9:** `record()` no debe reabrir un journal ajeno; exigir el `sessionId` correcto.
7. **A1:** forzar `requiresOnDeviceRecognition = true`. Si no está soportado, error visible y no enviar audio al servidor.
8. **A2 y A3:** reasignar el ring buffer tras un cambio de formato; en un media services reset, recrear el engine y reconfigurar la sesión.
9. **Telemetría honesta:** valores reales en `carryOverMs` y `formatsMatch`; `TAP_FIRST_BUFFER` al llegar el primer buffer; nueva señal `TAP_STALL` (sin buffers durante N ms con engine en marcha); `THERMAL_STATE`; memoria.
10. **Guardar audio de la reunión** (`MeetingAudioWriter`), conmutable y borrado al archivar. Habilita la medición, la diarización y el refinamiento posteriores.
11. **Diarización MVP (tras 1–10):** pasada definitiva **al detener** con FluidAudio offline, con prefijo `Hablante N:` en cada línea. Añade **una dependencia SPM** y **requiere tu aprobación**.

> Los puntos 1–10 no cambian la arquitectura, y cada uno tiene un test que falla con el código actual (regla de la memoria del proyecto: validar los tests en ambas direcciones).

## 8. Solución avanzada

1. **Motor:** `SpeechAnalyzer` con `SpeechTranscriber`, respaldo `DictationTranscriber` y `SpeechDetector`, detrás de `SpeechEngineProtocol`, como `AppleSpeechAnalyzerEngine`.
   - Consecuencias: desaparecen la rotación, el watchdog `RECOGNIZER_DEAF` y la detección heurística de reinicios.
   - El segmentador trabaja sobre resultados **finales con rango de audio**.
2. **Línea temporal absoluta:** cada frase lleva su rango en muestras del audio guardado.
3. **Diarización en dos niveles:**
   - provisional cada ~10 s: FluidAudio `DiarizerManager` + `SpeakerManager`, o LS-EEND si la reunión tiene ≤10 personas;
   - definitiva al detener, con remapeo húngaro.
4. **VAD independiente** (Silero v6.2) para telemetría "hay voz pero no llega texto" y para recortar silencios antes de diarizar.
5. **Refinamiento opcional en A15+ o iPad:** re-transcribir frases con baja confianza usando Parakeet TDT v2 (FluidAudio, fp16) sobre `[inicio − 1,5 s, fin + 1 s]`. Reglas:
   - solo si el gobernador térmico lo permite;
   - resultado como corrección en el journal;
   - desactivado por defecto en A14.
6. **Interfaz:**
   - `AVInputPickerInteraction` para elegir micrófono;
   - indicador de nivel con aviso "hablante demasiado lejos";
   - etiqueta de hablante provisional atenuada que se consolida al terminar.

---

## 9. Plan de implementación por fases

| Fase | Contenido | Dependencias nuevas | Salida verificable |
|---|---|---|---|
| **0. Medir** | Telemetría honesta (punto 9 del MVP) + corpus de pruebas de la sección 10 + medición base con el motor actual | No | Informe base: % audio perdido, WER, latencia, temperatura en iPhone 12 |
| **1. Pipeline sin pérdidas** | MVP 1–8 con tests de regresión en ambas direcciones | No | P1–P9 y A1–A3 cerrados; la métrica "palabras de referencia recuperadas" mejora frente a la Fase 0 |
| **2. Audio persistente** | `MeetingAudioWriter`, recuperación y borrado al archivar | No | Tras kill -9: audio y texto recuperados hasta el último segundo |
| **3. SpeechTranscriber** | `AppleSpeechAnalyzerEngine` + A/B contra SFSpeech con el mismo corpus | No (framework del sistema) | WER y % perdido iguales o mejores en iPhone 12; sin rotaciones |
| **4. Diarización al detener** | FluidAudio offline + `SpeakerAssignment` + prefijo en exportación | **Sí (FluidAudio, SPM)** | DER medido; pico de memoria en 2 h en A14 < umbral |
| **5. Diarización en vivo** | Provisional ~10 s + remapeo estable | Misma | Tasa de cambios de etiqueta visibles al consolidar; temperatura |
| **6. Refinamiento (opcional)** | Parakeet en A15+ o iPad | Modelo descargado | Mejora de WER sin empeorar temperatura |

Cada fase se puede enviar por separado y revertir sin afectar a las anteriores.

---

## 10. Plan de pruebas y criterios de aceptación

### 10.1 Corpus reproducible

- **Material base:**
  - grabaciones propias con guion y transcripción de referencia;
  - reproducción por altavoz en sala de reuniones de **AMI Meeting Corpus** (CC-BY-4.0, con transcripción y diarización de referencia).
  - El altavoz se coloca a distancias fijas del iPhone, con volumen calibrado con sonómetro (dB SPL anotado).
- **Matriz de escenarios:**

| Dimensión | Valores |
|---|---|
| Personas | 1, 2, 3, 5 (y un caso de 8–10) |
| Distancia al dispositivo | 0,5 m, 1,5 m, 3 m |
| Voces | Masculinas, femeninas y mezcla; acentos en inglés (US, UK, India, hispanohablante, otros disponibles) |
| Ruido de fondo | Silencio, oficina (~50 dBA), cafetería (~65 dBA) |
| Ritmo | Pausas largas (>5 s), frases rápidas, turnos de una palabra ("Yes.", "Okay.") |
| Solape | Interrupciones y habla simultánea, con guion |
| Eventos del sistema | Llamada entrante, alarma, conectar o desconectar AirPods y cable, Siri, bloqueo de pantalla, media services reset (Ajustes de desarrollador), kill -9 |
| Duración | 15, 60 y 120 min |
| Dispositivos | iPhone 12 (A14, obligatorio), un A15/A16, un A17 Pro+ y un iPad (A14 o M) |

### 10.2 Métricas y cómo medirlas

Todo el cálculo se hace **localmente** (Mac del desarrollador); no se sube nada.

| Métrica | Definición / herramienta |
|---|---|
| **WER** | (S + D + I) / N contra la referencia, normalizando mayúsculas y puntuación (jiwer u otra implementación local) |
| **% palabras perdidas** | Palabras de la referencia sin correspondencia en la salida (componente D del WER), separando zonas de interrupción esperada |
| **% audio perdido** | 1 − (duración de audio entregado por el tap / duración de reloj de pared) excluyendo `suspended`; con `AUDIO_GAP` y `TAP_STALL` |
| **Duplicados** | Palabras insertadas que repiten texto ya confirmado (componente I atribuible) |
| **DER** | (falsa alarma + omisión + confusión) / tiempo de voz, con `pyannote.metrics` local; reportar sin collar y con collar 0,25 s |
| **Confusión de hablantes** | Componente de confusión del DER + número de hablantes estimados frente a reales |
| **Estabilidad del ID** | Nº de frases cuyo hablante cambia al consolidar la pasada final |
| **Latencia hasta frase** | Fin de la frase en el audio → `commitPhrase` (telemetría); p50 y p95 |
| **Batería** | % por hora (Instruments Energy Log / MetricKit, local) |
| **Memoria máxima** | `phys_footprint` pico (Instruments / MetricKit) |
| **Temperatura** | Tiempo en cada `thermalState`; minutos hasta `.serious` |
| **Recuperación** | Tras kill -9 o reinicio: % frases recuperadas, segundos de audio perdidos, hablantes recuperados |

### 10.3 Criterios de aceptación propuestos

Son **objetivos iniciales a calibrar tras la Fase 0**, no mediciones.

| Criterio | Objetivo |
|---|---|
| Pérdidas de lógica | P1–P9: 0 casos en tests unitarios y en el corpus (cada test falla con el código actual) |
| Audio perdido fuera de interrupciones | < 0,5 % en 60 min, en iPhone 12 |
| Frase al detener | 100 % de las frases dichas hasta 1 s antes de detener aparecen |
| Palabras de referencia recuperadas | ≥ Fase 0 + mejora medible; nunca peor en ningún escenario |
| WER con SpeechTranscriber frente a SFSpeech | No peor en ningún escenario; mejor en 1,5–3 m |
| Latencia p95 hasta frase | ≤ 2,5 s |
| DER al detener (2–4 personas, 1,5 m, sin collar) | ≤ 25 % |
| DER al detener con 5+ personas | Reportar, sin objetivo comprometido |
| Etiquetas corregidas al consolidar | ≤ 15 % |
| 120 min en iPhone 12 | Sin `.critical`; sin cierre por memoria; batería medida y documentada |
| Pico de memoria en iPhone 12 durante la diarización final de 2 h | ≤ 1 GB (a validar) |
| Recuperación tras kill -9 | Texto hasta la última frase confirmada; audio hasta el último bloque (≤ 1 s) |

---

## 11. Riesgos y limitaciones

| Riesgo | Tipo | Mitigación |
|---|---|---|
| Apple no publica la lista de dispositivos de `SpeechTranscriber` | Compatibilidad | `isAvailable` en tiempo de ejecución + `DictationTranscriber` + probar en iPhone 12 real antes de la Fase 3 |
| No hay cifras de WER de `SpeechTranscriber` en iPhone ni en reuniones lejanas | Evidencia | Medición propia con el corpus (Fase 0/3) |
| DER alto con muchos hablantes y un solo micrófono | Precisión | Expectativas explícitas en la interfaz; pasada final; edición manual |
| Memoria del clustering con 2 h en 4 GB | Rendimiento | Medir primero; clustering por bloques si no cabe |
| Temperatura y batería en 2 h con diarización en vivo | Rendimiento | Gobernador térmico; en vivo desactivable; A14 con perfil ligero |
| Guardar audio de reuniones confidenciales | Privacidad | Solo en el dispositivo, protección de archivo, borrado al archivar, opción de desactivar |
| Embeddings de voz como dato biométrico | Legal | No persistir tras la reunión; aviso; sin identificación entre reuniones |
| FluidAudio: proyecto joven de un tercero; modelos CC-BY-4.0 que exigen atribución | Dependencia / licencia | Versión fija (no rama), pantalla de atribuciones, adaptador detrás de un protocolo de dominio |
| FluidAudio requiere iOS 17 (compatible con 26.1) y descarga modelos (~100 MB) | Distribución | Descarga en el primer uso con `BackgroundAssetsCoordinator` (dirección permitida) |
| Argmax Pro renueva la licencia online | Regla on-device | No adoptarlo |
| Solape de voces: una sola transcripción | Limitación de ASR | Marcar como superpuesto |
| El modo `.measurement` o voice processing pueden empeorar | Captura | Solo con A/B medido |
| Revertir la decisión de `CLAUDE.md` que aplazó SpeechAnalyzer | Proceso | Necesita tu aprobación explícita |
| La base de datos (SwiftData) solo guarda dos bloques de texto | Datos | Prefijo `Hablante N:` en línea, sin migración (respeta la decisión Q2); migrar solo si se quiere editar hablantes después |

---

## 12. Fuentes consultadas

Todas **consultadas el 2026-09-15**. Entre paréntesis, la fecha de publicación o versión cuando existe.

**Apple**
- SpeechAnalyzer (iOS 26.0): https://developer.apple.com/documentation/speech/speechanalyzer
- SpeechTranscriber: https://developer.apple.com/documentation/speech/speechtranscriber
- SpeechDetector: https://developer.apple.com/documentation/speech/speechdetector
- Símbolos del framework Speech (JSON): https://developer.apple.com/tutorials/data/documentation/speech.json
- Novedades de Speech (incl. junio 2026): https://developer.apple.com/tutorials/data/documentation/updates/speech.json
- SpeechTranscriber.ResultAttributeOption: https://developer.apple.com/tutorials/data/documentation/speech/speechtranscriber/resultattributeoption.json
- SFTranscription / SFTranscriptionSegment / SFVoiceAnalytics: https://developer.apple.com/documentation/speech/sftranscriptionsegment
- requiresOnDeviceRecognition: https://developer.apple.com/documentation/speech/sfspeechrecognitionrequest/requiresondevicerecognition
- WWDC25 277, "Bring advanced speech-to-text to your app with SpeechAnalyzer" (jun 2025): https://developer.apple.com/videos/play/wwdc2025/277/
- WWDC25 251, grabación de audio (jun 2025): https://developer.apple.com/videos/play/wwdc2025/251/
- WWDC26, vídeos (jun 2026): https://developer.apple.com/videos/wwdc2026/
- WWDC26 256, Generated subtitles: https://developer.apple.com/videos/play/wwdc2026/256/
- WWDC26 241, Foundation Models: https://developer.apple.com/videos/play/wwdc2026/241/
- WWDC23 10235, voice processing: https://developer.apple.com/videos/play/wwdc2023/10235/
- AVAudioSession.Mode.measurement: https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/measurement
- AVAudioSession.Mode.voiceChat: https://developer.apple.com/documentation/avfaudio/avaudiosession/mode-swift.struct/voicechat
- bluetoothHighQualityRecording: https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/bluetoothhighqualityrecording
- preferredMicrophoneMode: https://developer.apple.com/documentation/avfoundation/avcapturedevice/preferredmicrophonemode
- setPreferredPolarPattern: https://developer.apple.com/documentation/avfaudio/avaudiosessiondatasourcedescription/setpreferredpolarpattern(_:)
- ProcessInfo.ThermalState: https://developer.apple.com/documentation/foundation/processinfo/thermalstate-swift.enum
- BGContinuedProcessingTaskRequest: https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtaskrequest
- TN3193, contexto de Foundation Models (act. 2026-03-31): https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window
- Foros de Apple: 802863, respuesta DTS sobre disponibilidad (oct 2025): https://developer.apple.com/forums/thread/802863
- Foros de Apple: 806765, dispositivos compatibles según la comunidad (nov 2025–mar 2026): https://developer.apple.com/forums/thread/806765
- Foros de Apple: 801229, GPU en segundo plano: https://developer.apple.com/forums/thread/801229
- Apple Newsroom, iPhone 12 / A14 (oct 2020): https://www.apple.com/newsroom/2020/10/apple-announces-iphone-12-and-iphone-12-mini-a-new-era-for-iphone-with-5g/

**ASR**
- Argmax, "Apple SpeechAnalyzer and Argmax WhisperKit" (2025-06-20): https://www.argmaxinc.com/blog/apple-and-argmax
- MacStories, prueba práctica de SpeechAnalyzer (jun 2025): https://www.macstories.net/stories/hands-on-how-apples-new-speech-apis-outpace-whisper-for-lightning-fast-transcription/
- WhisperKit / Argmax OSS: releases (v1.1.0, 2026-08-06): https://github.com/argmaxinc/WhisperKit/releases
- WhisperKit, paper arXiv 2507.10860 (2025-07-14): https://arxiv.org/html/2507.10860
- whisperkit-coreml config.json (modelos por dispositivo): https://huggingface.co/argmaxinc/whisperkit-coreml/resolve/main/config.json
- Argmax, precios: https://www.argmaxinc.com/pricing
- Argmax, Pro SDK GA: https://www.argmaxinc.com/blog/pro-sdk-ga
- whisper.cpp (v1.9.4, 2026-09-11): https://github.com/ggml-org/whisper.cpp
- NVIDIA Parakeet TDT 0.6B v2 (2025-05-01): https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2
- NVIDIA Parakeet TDT 0.6B v3 (2025-08-14): https://huggingface.co/nvidia/parakeet-tdt-0.6b-v3
- Open ASR Leaderboard, paper v4 (2026-03-30): https://arxiv.org/html/2510.06961v4
- NVIDIA Canary-1b-flash: https://huggingface.co/nvidia/canary-1b-flash
- FluidAudio (v0.15.7, 2026-09-10): https://github.com/FluidInference/FluidAudio
- FluidAudio, Benchmarks: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Benchmarks.md
- FluidAudio, primeros pasos con ASR: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/ASR/GettingStarted.md
- Parakeet EOU 120M Core ML: https://huggingface.co/FluidInference/parakeet-realtime-eou-120m-coreml
- Moonshine v2, arXiv 2602.12241 (2026-02-12): https://arxiv.org/html/2602.12241v1
- Moonshine, repositorio (v0.1.5, 2026-08-24): https://github.com/moonshine-ai/moonshine
- sherpa-onnx en iOS (v1.13.8, 2026-09-10): https://k2-fsa.github.io/sherpa/onnx/ios/index.html
- Vosk (v0.3.50, 2024-04-22): https://github.com/alphacep/vosk-api
- Macháček et al., LocalAgreement, arXiv 2307.14743 (2023-07-27): https://arxiv.org/abs/2307.14743

**VAD y reducción de ruido**
- Silero VAD: repositorio: https://github.com/snakers4/silero-vad
- Silero VAD: releases (v6.2 2025-11-06; v6.2.1 2026-02-24): https://github.com/snakers4/silero-vad/releases
- TEN VAD (v1.0, 2025-07-11): https://github.com/TEN-framework/ten-vad
- TEN VAD, licencia: https://github.com/TEN-framework/ten-vad/blob/main/LICENSE
- pyannote segmentation-3.0: https://huggingface.co/pyannote/segmentation-3.0
- RNNoise, demo (J.-M. Valin): https://jmvalin.ca/demo/rnnoise/
- DeepFilterNet (último release 2023-08-31): https://github.com/Rikorose/DeepFilterNet
- arXiv 2512.17562, realce de voz frente a ASR (dic 2025): https://arxiv.org/abs/2512.17562
- arXiv 2603.04710, preprocesado frente a Whisper (2026): https://arxiv.org/abs/2603.04710

**Diarización**
- pyannote speaker-diarization-community-1 (sep 2025): https://huggingface.co/pyannote/speaker-diarization-community-1
- pyannote.audio: https://github.com/pyannote/pyannote-audio
- pyannote WeSpeaker ResNet34-LM: https://huggingface.co/pyannote/wespeaker-voxceleb-resnet34-LM
- pyannoteAI, modelos: https://docs.pyannote.ai/models
- FluidAudio, primeros pasos con diarización: https://github.com/FluidInference/FluidAudio/blob/main/Documentation/Diarization/GettingStarted.md
- FluidAudio, releases: https://github.com/FluidInference/FluidAudio/releases
- Modelos Core ML de FluidInference, diarización de hablantes: https://huggingface.co/FluidInference/speaker-diarization-coreml
- Modelos Core ML de FluidInference, LS-EEND: https://huggingface.co/FluidInference/ls-eend-coreml
- Modelos Core ML de FluidInference, Sortformer: https://huggingface.co/FluidInference/diar-streaming-sortformer-coreml
- inference.plus, diarización casi en tiempo real con Core ML (2025-08-01): https://inference.plus/p/low-latency-speaker-diarization-on
- Argmax, SpeakerKit (2025-03-07): https://www.argmaxinc.com/blog/speakerkit
- Argmax, pyannoteAI en Argmax (2025-06-23): https://www.argmaxinc.com/blog/pyannote-argmax
- Argmax, argmax-oss-swift: https://github.com/argmaxinc/argmax-oss-swift
- SDBench (Interspeech 2025): https://www.isca-archive.org/interspeech_2025/durmus25_interspeech.pdf
- NVIDIA Streaming Sortformer v2: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2
- NVIDIA Streaming Sortformer v2.1: https://huggingface.co/nvidia/diar_streaming_sortformer_4spk-v2.1
- NVIDIA TitaNet-L: https://huggingface.co/nvidia/speakerverification_en_titanet_large
- sherpa-onnx, diarización: https://k2-fsa.github.io/sherpa/onnx/speaker-diarization/index.html
- 3D-Speaker: https://github.com/modelscope/3D-Speaker
- WeSpeaker, modelos preentrenados: https://github.com/wenet-e2e/wespeaker/blob/master/docs/pretrained.md
- SpeechBrain ECAPA: https://huggingface.co/speechbrain/spkrec-ecapa-voxceleb
- diart, Coria et al. (ASRU 2021): https://arxiv.org/abs/2109.06483
- LS-EEND, arXiv 2410.06670 (oct 2024): https://arxiv.org/abs/2410.06670
- WhisperX: https://github.com/m-bain/whisperX

**Legal**
- RGPD, art. 9: https://gdpr-info.eu/art-9-gdpr/
- Illinois BIPA (740 ILCS 14, enmienda 2024-08-02): https://www.ilga.gov/documents/legislation/ilcs/documents/074000140K15.htm
- Colombia, Ley 1581 de 2012: http://www.secretariasenado.gov.co/senado/basedoc/ley_1581_2012.html

**No verificado en esta investigación:**
- NeMo MSDD, UIS-RNN y WebRTC VAD en fuente primaria.
- La licencia de `reverb-diarization-v1`.
- Cualquier benchmark de rendimiento en A14.
- Consumo y temperatura de 2 h de inferencia continua.

---

## 13. Archivos y componentes a modificar

Rutas relativas a `TranslatorApp/`. Nada de esto se ha tocado.

### Fase 0–1 (pipeline y telemetría, sin dependencias)

| Archivo | Cambio |
|---|---|
| `Presentation/ViewModels/TranscriptionViewModel+Session.swift` | Orden de apagado en `stopRecording` (P1) |
| `Presentation/ViewModels/TranscriptionViewModel.swift` | `restartListening` (P1); ámbito de `fragmentKeys` (P2) |
| `Presentation/ViewModels/TranscriptionViewModel+Fragments.swift` | Deduplicación acotada (P2) |
| `Domain/UseCases/TranscribeAudioUseCase.swift` | `stop()` ordenado; salir de `MainActor`; conservar `sessionGeneration` en correcciones (D4) |
| `Data/Respository/SpeechRepository.swift` | Salir de `MainActor` |
| `Domain/Services/NLPSegmenterService.swift` | Vaciar la cola al cambiar de generación (P4); umbral de reinicio (P7) |
| `Domain/Services/NLPSegmenterService+Timing.swift` | Frases de 1 palabra completas (P5); techo tras un corte (P6) |
| `Domain/Services/NLPSegmenterService+Text.swift` | Anclas mínimas (P8), D1/D2 |
| `Data/Correctors/FoundationModelsCorrector.swift` | Propagar `sessionGeneration` (D4) |
| `Data/SpeechEngines/AppleSFSpeechEngine.swift` | `requiresOnDeviceRecognition = true` estricto (A1); orden `endAudio`/`finish`; carrera drain/swap (A5) |
| `Data/SpeechEngines/AppleSFSpeechEngine+Rotation.swift` | No cancelar antes del final o ampliar la reinyección (P3); telemetría real de carry-over |
| `Data/SpeechEngines/AppleSFSpeechEngine+Resilience.swift` | Media services reset (A3) |
| `Data/Audio/AudioRingBuffer.swift` | Reasignar tras un cambio de formato (A2); capacidad configurable |
| `Data/Audio/AudioCaptureSession.swift` | `TAP_FIRST_BUFFER` real, `TAP_STALL`, `formatsMatch` real; recrear el engine |
| `Data/Audio/AudioSessionCoordinator.swift` / `+Observation.swift` | Reconfigurar tras reset; revisar la ventana de 800 ms (A4); telemetría del micrófono elegido |
| `Data/Persistence/FileTranscriptJournal.swift` | No reabrir journals ajenos (P9) |
| `Domain/Entities/TelemetryEvent.swift`, `Domain/Interfaces/PipelineTelemetry+Events.swift`, `PipelineTelemetryProtocol.swift` | Eventos `TAP_STALL`, `THERMAL_STATE`, `MEMORY` |
| `App/DependencyContainer.swift` | Tamaño del ring buffer; observador térmico |
| `TranslatorAppTests/` | Tests nuevos para P1–P9, D1–D4, A2 (fallan con el código actual) |

### Fase 2 (audio persistente)

| Archivo | Cambio |
|---|---|
| **Nuevo** `Data/Audio/MeetingAudioWriter.swift` | Escritura por bloques, protección de archivo, reloj de muestras |
| **Nuevo** `Domain/Interfaces/MeetingAudioStoreProtocol.swift` | Contrato de dominio |
| `Data/Audio/AudioCaptureSession.swift` | Alimentar el writer desde el tap (solo copia) |
| `Presentation/ViewModels/TranscriptionViewModel+Archive.swift` / `+Recovery.swift` | Borrar o recuperar el audio |
| `Domain/Entities/TranscriptJournalEntry.swift` | Rango de audio por frase |

### Fase 3 (SpeechTranscriber)

| Archivo | Cambio |
|---|---|
| **Nuevo** `Data/SpeechEngines/AppleSpeechAnalyzerEngine.swift` (+ extensiones) | `SpeechAnalyzer` + `SpeechTranscriber`/`DictationTranscriber` + `SpeechDetector` |
| `Domain/Interfaces/SpeechEngineProtocol.swift`, `Domain/Entities/SpeechSegment.swift` | Rango de audio, volátil/final |
| `Domain/Entities/EnginePreference.swift`, `EngineId.swift`, `Presentation/Views/Settings/EnginePreferenceView.swift` | Selección y A/B |
| `Data/Coordinators/BackgroundAssetsCoordinator.swift` | `AssetInventory` para el modelo de Apple |
| `Domain/Services/NLPSegmenterService*.swift`, `LiveTailReconciler.swift` | Consumir resultados finales con rango; deduplicación por tiempo |
| `App/DependencyContainer.swift` | Elegir el motor según `isAvailable` |
| `CLAUDE.md` | Actualizar la decisión sobre SpeechAnalyzer |

### Fases 4–5 (diarización)

| Archivo | Cambio |
|---|---|
| **Nuevo** `Domain/Entities/SpeakerLabel.swift`, `SpeakerTurn.swift` | Entidades |
| **Nuevo** `Domain/Interfaces/SpeakerDiarizerProtocol.swift` | Contrato (provisional / definitivo) |
| **Nuevo** `Domain/Services/SpeakerAssignment.swift` | Puro: frase ↔ turnos por solape; solape → "superpuesto" |
| **Nuevo** `Domain/Services/SpeakerIdentityMapper.swift` | Puro: remapeo húngaro provisional → definitivo |
| **Nuevo** `Data/Diarization/FluidAudioDiarizer.swift` | Adaptador de FluidAudio (versión fija) |
| **Nuevo** `Data/Diarization/ThermalGovernor.swift` | Pausa por `thermalState` |
| `Domain/Entities/ConversationFragment.swift` | `speaker` (provisional/definitivo) |
| `Domain/Entities/TranscriptJournalEntry.swift` | Entradas `speakerAssignment` y `diarizationCheckpoint` |
| `Data/Persistence/FileTranscriptJournal.swift` | Recuperación de hablantes y checkpoint |
| `Domain/Interfaces/NLPSegmenterServiceProtocol.swift`, `NLPSegmenterService.swift` | No unir turnos de distinto hablante |
| `Domain/Services/ConversationTextFormatter.swift`, `Domain/UseCases/SaveConversationUseCase.swift` | Prefijo `Hablante N:` manteniendo el número de líneas |
| `Presentation/ViewModels/TranscriptionViewModel+Fragments.swift`, `+Archive.swift`, `+Recovery.swift` | Asignación, consolidación, borrado de embeddings |
| `Presentation/Views/LiveTranscriptionPanes.swift`, `ConversationDetailView.swift`, `ConversationExport.swift` | Etiqueta de hablante (provisional atenuada) |
| `App/DependencyContainer.swift` | Cableado |
| `Data/Models/ConversationRecord.swift` | **Sin cambios** si se usa prefijo en línea (decisión Q2) |
| `TranslatorApp.xcodeproj` | Paquete FluidAudio con versión fija (requiere aprobación) |

---

## Anexo A. Privacidad: nada de la conversación sale de la app

**Regla del usuario (2026-09-15), sin excepciones:**
- Ningún audio ni texto de la conversación sale de la aplicación, nunca.
- Al terminar, el usuario decide si **guarda** o **comparte** la conversación.
- Lo guardado se almacena **cifrado**.
- Compartir es la única salida permitida, y solo por acción explícita del usuario.

### A.1 Vías de salida encontradas en el código actual

| # | Vía | Estado | Ref. | Corrección propuesta |
|---|---|---|---|---|
| S1 | **Reconocimiento en servidor de Apple** si `supportsOnDeviceRecognition` es `false` | [C✔] Posible hoy | `Data/SpeechEngines/AppleSFSpeechEngine.swift:170,267-269` | `requiresOnDeviceRecognition = true` siempre. Si no hay soporte local: no iniciar y mostrar un error claro. Test que lo garantice. |
| S2 | **Copia de seguridad de iCloud / del dispositivo.** La base SwiftData y el journal viven en Application Support, que iOS incluye por defecto en las copias de seguridad. Una copia de iCloud **sube la conversación a Apple**. | [C✔] Sin `isExcludedFromBackup` en el código | `App/DependencyContainer.swift:106`; `Data/Persistence/FileTranscriptJournal.swift:55` | Marcar la base, el journal y el audio con `isExcludedFromBackup = true`. Revisarlo en cada arranque, porque el atributo se pierde al recrear el archivo. |
| S3 | **Base SwiftData sin cifrado propio.** Texto en claro dentro del contenedor, con la protección por defecto. | [C✔] `ModelContainer` con configuración por defecto | `App/DependencyContainer.swift:106-107` | Ver A.2 |
| S4 | **Journal en texto plano JSON** | [C✔] | `Data/Persistence/FileTranscriptJournal.swift:103-108` | Cifrar cada línea (A.2) |
| S5 | **Texto transcrito en logs.** El corrector registra la frase original y la corregida. OSLog redacta por defecto las cadenas dinámicas (`<private>`), pero es texto de la conversación en un log que puede acabar en un sysdiagnose. | [C✔] | `Data/Correctors/FoundationModelsCorrector.swift:41,51` | Eliminar el texto de esos logs; solo recuentos (regla de telemetría ya existente) |
| S6 | **Compartir.** `ShareLink` exporta un `.txt` en claro. | [C✔] Iniciado por el usuario: **permitido** | `Presentation/Views/LiveTranscriptionView.swift:217`, `ConversationDetailView.swift:77` | Mantener, siempre por acción explícita. No ofrecer "copiar al portapapeles" sin aviso: el Portapapeles Universal lo sincroniza con otros dispositivos. |
| S7 | Sincronización con CloudKit | [C✔] No existe: el proyecto no tiene archivo `.entitlements` ni capacidad iCloud | — | Mantenerlo así; test o check de build |
| S8 | Red en general | [C✔] Solo `BackgroundAssetsCoordinator`, que descarga un modelo (dirección permitida) | `Data/Coordinators/BackgroundAssetsCoordinator.swift:86-99` | Cualquier dependencia nueva (p. ej. FluidAudio) debe auditarse: sin telemetría ni subida de datos, solo descarga de modelos |

### A.2 Diseño de cifrado propuesto

Todo con frameworks del sistema; sin dependencias.

- **Algoritmo:** CryptoKit `AES.GCM` con clave simétrica de 256 bits.
- **Clave:**
  - generada en el primer uso y guardada en el **Keychain** con `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`;
  - *ThisDeviceOnly*: no viaja en copias de seguridad ni en el Llavero de iCloud;
  - *AfterFirstUnlock*: permite escribir con la pantalla bloqueada (decisión Q3).
- **Journal:** cada línea es un registro cifrado independiente (nonce + ciphertext + tag, en base64). Se conserva la propiedad actual: un cierre abrupto solo puede dañar la última línea.
- **Conversaciones guardadas:** los campos de texto de `ConversationRecord` se guardan como `Data` cifrada, o bien los bloques de texto se cifran antes de persistir. Implica una migración de esquema, **en conflicto con la decisión Q2 de 008**: requiere tu aprobación.
- **Audio (si se aprueba guardarlo):** bloques cifrados con la misma clave, borrados al guardar o descartar la reunión.
- **Protección de archivo:** se mantiene `.completeUntilFirstUserAuthentication` como segunda capa, y se añade `isExcludedFromBackup`.
- **Consecuencia aceptada:** si el usuario borra la app o restaura el iPhone desde una copia, la clave no existe y las conversaciones guardadas **no se pueden recuperar**. Es coherente con "nunca sale del dispositivo"; debe decirse en la interfaz.
- **Opcional:** Face ID / código (`LocalAuthentication`) para abrir el historial.

### A.3 Conflicto con la feature 010 que hay que resolver

La feature 010 **archiva cada reunión automáticamente al detener** (`Presentation/ViewModels/TranscriptionViewModel+Archive.swift:36-61`). La nueva regla dice que el usuario **elige** si guarda o comparte.

Propuesta que respeta ambas cosas (el texto no se pierde y el usuario decide):
1. **Durante la reunión:** el journal cifrado sigue escribiéndose en cada frase. Es protección ante cierres, no un "guardado".
2. **Al detener:** pantalla con **Guardar (cifrado)**, **Compartir** y **Descartar**. Descartar pide confirmación.
3. **Mientras no decide:** el journal cifrado permanece. Si la app se cierra, al abrirla se ofrece la misma elección.
4. **Guardar:** pasa la reunión al historial cifrado y borra el journal. **Descartar** borra el journal, el audio y los embeddings.
5. **Compartir sin guardar:** tras compartir se vuelve a ofrecer Guardar o Descartar. Nada se borra sin confirmación.

### Decisiones pendientes de tu aprobación antes de implementar

1. Empezar por las **Fases 0–1** (sin dependencias, sin cambio de modelo).
2. **Guardar el audio de la reunión en el dispositivo** (y borrarlo al archivar).
3. **Reabrir la decisión de `CLAUDE.md`** y migrar a `SpeechAnalyzer`/`SpeechTranscriber`.
4. **Añadir FluidAudio** como dependencia SPM para la diarización.
5. **Sustituir el archivado automático (010)** por la elección Guardar / Compartir / Descartar del Anexo A.3.
6. **Migración de esquema de SwiftData** para guardar cifrado (reabre la decisión Q2 de 008).
