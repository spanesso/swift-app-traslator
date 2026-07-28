# Informe de investigación — Pérdida de palabras y reconocimiento deficiente en el ASR

**Proyecto:** TranslatorApp (swift-app-traslator)
**Branch:** `005-accent-robust-asr`
**Fecha:** 2026-07-14
**Síntoma reportado:** la app falla al reconocer las voces; a veces "se queda corta" y no reconoce bien las palabras.

---

## Resumen ejecutivo

El síntoma no tiene una sola causa: hay **defectos estructurales en los tres motores de ASR**, y el más grave depende de qué motor está corriendo realmente en el dispositivo. Lo más probable es que hoy esté corriendo el motor *legacy* (`ContinuousSpeechListener`), que **pierde audio físicamente en cada reinicio de reconocimiento** (cada pausa del hablante y cada ~60 s). Además, el motor WhisperKit — la apuesta del feature 005 — tiene defectos que lo hacen inviable en su estado actual, incluyendo un formato de audio que muy probablemente crashea o silencia la captura en dispositivo real.

**Recomendación inmediata:** aplicar los fixes de la Fase 1 (motor legacy) — son pequeños y atacan directamente el síntoma. WhisperKit requiere una fase propia de corrección antes de aportar valor.

---

## 1. Qué motor corre realmente

La selección de motor ocurre en `DependencyContainer.swift:52-65`:

| Condición | Motor seleccionado |
|---|---|
| Usuario fuerza "Apple only" | `AppleSpeechAnalyzerEngine` |
| iPhone 15 Pro+ (A17 Pro) **y** flag `whsk.installed` en true | `WhisperKitEngine` |
| Cualquier otro caso | `LegacySFSpeechEngine` → `ContinuousSpeechListener` |

El flag `whsk.installed` solo se activa si el usuario aceptó **y completó** la descarga de ~600 MB del modelo. Salvo que eso haya ocurrido, **la app corre el pipeline viejo de `SFSpeechRecognizer`**.

> **Primer paso de diagnóstico:** confirmar en OSLog qué línea `[Container] engine=...` aparece al arrancar la app.

---

## 2. Hallazgos — Motor legacy (el que probablemente corre hoy)

### H1 — Pérdida de audio en cada reinicio ⚠️ causa principal del "se queda corto"

En `ContinuousSpeechListener.swift:126-157`, cada vez que `SFSpeechRecognizer` emite un resultado final (ocurre en cada pausa del hablante y al tope de ~60 s), se cancela la tarea, se espera 150 ms y se crea un request nuevo. Durante ese intervalo (150 ms + el arranque interno del reconocedor, que puede ser 0.5–1 s) el tap de audio sigue alimentando el request **ya cancelado**: esas palabras se pierden sin rastro.

Un hablante que retoma rápido después de una pausa pierde el inicio de la frase sistemáticamente. `AppleSpeechAnalyzerEngine.swift:110-123` tiene exactamente el mismo defecto.

### H2 — Modo de audio `.measurement`

Los tres motores configuran `AVAudioSession` con `mode: .measurement` (`ContinuousSpeechListener.swift:57`), que **desactiva el procesamiento de señal del sistema** (ganancia automática, reducción de ruido). Para hablantes con acento, voz baja o distancia del micrófono — exactamente el público objetivo del feature 005 — esto degrada el SNR de entrada. `.measurement` es apropiado para instrumentación, no para dictado.

### H3 — Request de reconocimiento sin configurar

El `SFSpeechAudioBufferRecognitionRequest` no fija:

- `taskHint = .dictation`
- `addsPunctuation = true` — la segmentación por frases del `NLPSegmenterService` depende de puntuación que casi nunca llega
- `contextualStrings` para vocabulario de dominio

Cada una de estas es una pérdida de precisión gratuita.

### H4 — Confianza de parciales contamina las métricas

`SFSpeechRecognizer` reporta confianza 0.0 en resultados parciales. `QualityMetricsService.isLowQualitySpeech()` usa `avgConfidence < 0.6` (`QualityMetricsService.swift:112`), así que la sesión queda marcada "low quality" casi siempre y el segmentador opera con el timer largo (1.2 s), aumentando la latencia percibida sin razón real.

### H5 — Carrera en `AppleSpeechAnalyzerEngine.start()`

La continuation del stream se asigna dentro de un `Task` asíncrono (`AppleSpeechAnalyzerEngine.swift:37-39`) pero el reconocimiento arranca inmediatamente después: los primeros segmentos pueden emitirse antes de que exista la continuation y se descartan. **Palabras iniciales perdidas.**

---

## 3. Hallazgos — Motor WhisperKit (feature 005, incompleto)

### W1 — Formato del tap inválido 🛑 bloqueante

`WhisperKitEngine.swift:75-84` instala el tap del `inputNode` pidiendo Float32 a **16 kHz**, pero el hardware del iPhone captura a 48 kHz. `AVAudioEngine` exige que el formato del tap coincida con el sample rate del nodo; esto lanza una excepción en runtime (`IsFormatSampleRateAndChannelCountValid`) o falla la captura.

**Fix:** tapear al formato nativo del hardware y convertir con `AVAudioConverter` a 16 kHz mono antes de alimentar a Whisper. Este defecto sugiere que el motor nunca ha corrido con éxito en dispositivo.

### W2 — El buffer crece sin límite y se retranscribe completo cada 2 s

`scheduleTranscriptionLoop()` (`WhisperKitEngine.swift:101-117`) copia el `audioBuffer` completo — desde el inicio de la sesión — y lo transcribe entero en cada tick; solo se vacía al hacer stop. A los 30–60 s de sesión, cada pasada tarda más que la ventana de 2 s, el loop se atrasa sin recuperación y la transcripción "se congela". Whisper además trabaja en ventanas de 30 s: el audio largo se trocea internamente multiplicando el costo.

### W3 — No hay traducción en vivo con WhisperKit

Todos los segmentos de mitad de sesión salen con `isHypothesis: true` (`WhisperKitEngine.swift:150`); el use case los excluye del segmentador (`TranscribeAudioUseCase.swift:48`) y el único segmento final se emite al parar. Resultado: **el panel de español no recibe nada hasta detener la grabación**. El buffer `pendingHypothesis` del segmentador (`NLPSegmenterService.swift:28`) es código muerto — se llena y nunca se consume.

### W4 — La descarga del modelo no se conecta con el motor

`BackgroundAssetsCoordinator` descarga un zip a Application Support, **nunca lo descomprime**, y marca `whsk.installed = true` (`BackgroundAssetsCoordinator.swift:92-106`). Pero `WhisperKitEngine` inicializa `WhisperKit(WhisperKitConfig(model: "large-v3-turbo"))` sin `modelFolder`: ignora esa descarga y WhisperKit intenta bajar su propia copia de Hugging Face **al presionar grabar**, seguido de una carga de modelo de decenas de segundos, sin ningún feedback en la UI.

Problemas adicionales:

- La URL del coordinator (`.mlpackage.zip` único) no corresponde al formato real del repo `whisperkit-coreml` (carpetas con varios `.mlmodelc`).
- El paquete SPM está pineado a `main`, no a una versión — riesgo de reproducibilidad (la tarea T001 pedía v1.0.0 y sigue sin marcar).

### W5 — Umbral que descarta habla con acento

`firstTokenLogProbThreshold: -1.5` (`WhisperKitEngine.swift:126`) suprime ventanas cuyo primer token tiene baja probabilidad — que es precisamente lo que produce el habla acentuada. Ventanas enteras de habla legítima pueden descartarse: **palabras perdidas**.

### W6 — Ventanas de 2 s sin solapamiento ni contexto

Las palabras cortadas en el borde de ventana se pierden o se transcriben mal, y no se pasa el contexto previo como prompt. Este es el problema clásico que resuelve el patrón *LocalAgreement* / el `AudioStreamTranscriber` que WhisperKit ya trae incorporado.

---

## 4. Hallazgos transversales

- **`VADGate` no es un VAD:** filtra segmentos de **texto** vacíos, no audio (`VADGate.swift`). No previene alucinaciones de Whisper sobre silencio ni ayuda con ruido.
- **Confianza desincronizada en la UI:** `latestSegmentConfidence` en el ViewModel (`TranscriptionViewModel.swift:178`) asocia a cada traducción la confianza del último segmento crudo, no la del segmento traducido — el indicador de confianza puede marcar mal la frase equivocada.
- **Enunciados de 1 palabra suprimidos:** el segmentador descarta segmentos de ≤1 palabra salvo que sean finales (`NLPSegmenterService.swift:50-54`). Respuestas cortas ("Yes", "Okay") desaparecen con motores que rara vez emiten finales.

---

## 5. Plan de corrección recomendado

### Fase 0 — Medir antes de tocar (1–2 días)

1. Completar la tarea **T003**: el código del harness de evaluación (`WERCalculator`, `EvaluationHarness`, tests de EdAcc/LibriSpeech) ya existe pero el target de test no está en el proyecto.
2. Establecer el baseline de **WER por grupo de acento** — sin esto toda mejora es anecdótica (el propio spec 005 lo exige en el User Story 3).
3. Confirmar por logs qué motor corre en el dispositivo de prueba.

### Fase 1 — Arreglar el motor que la gente usa hoy (2–3 días, mayor retorno)

1. **Eliminar la brecha de reinicio (H1):** crear el request nuevo y redirigir el tap **antes** de finalizar el viejo (doble búfer), o acumular el audio del intervalo en un ring buffer y anteponerlo al request nuevo.
2. **Quitar `.measurement`** (usar modo `.default` o `.spokenAudio`) para recuperar AGC y reducción de ruido (H2).
3. **Configurar el request:** `taskHint = .dictation`, `addsPunctuation = true`, `contextualStrings` (H3).
4. **Arreglar la carrera de la continuation (H5)** y excluir confianzas de parciales de las métricas (H4).
5. **Consolidar:** `ContinuousSpeechListener` y `AppleSpeechAnalyzerEngine` son casi el mismo motor duplicado; quedarse con uno.

### Fase 2 — Hacer viable WhisperKit (1–2 semanas)

1. **Corregir el tap** con `AVAudioConverter` 48 kHz → 16 kHz mono (W1) — sin esto nada más importa.
2. **Reemplazar el loop artesanal por `AudioStreamTranscriber` de WhisperKit**, que ya implementa streaming con ventanas deslizantes, segmentos confirmados (emitibles como `isFinal` para que la traducción fluya en vivo, resolviendo W2 y W3) y VAD de energía (`chunkingStrategy: .vad`).
3. **Unificar la gestión del modelo:** o usar la descarga integrada de WhisperKit con callback de progreso hacia la UI existente de `ModelInstallState`, o pasar `modelFolder` apuntando a lo que descarga el coordinator (descomprimido). Precargar el modelo al seleccionar el motor, nunca al presionar grabar (W4). Pinear el paquete SPM a una versión.
4. **Quitar o relajar `firstTokenLogProbThreshold`** y validar contra el corpus acentuado (W5).
5. **Evaluar si `large-v3-turbo` es necesario:** en iPhone, la variante cuantizada (~626 MB) es la única razonable, y vale la pena medir `small`/`distil` en el harness — para frases conversacionales la diferencia de WER puede no justificar la latencia.

### Fase 3 — iOS 26 como Tier 0 real

El proyecto ya apunta a iOS 26 y `DeviceCapabilities.supportsEnhancedFrameworks` existe, pero ningún motor usa el nuevo **`SpeechAnalyzer`/`SpeechTranscriber`** de Apple (a pesar del nombre, `AppleSpeechAnalyzerEngine` sigue usando el `SFSpeechRecognizer` clásico). El API nuevo:

- Elimina el límite de ~60 s y los reinicios (la raíz de H1).
- Mejora la transcripción long-form.
- Es on-device.

Implementarlo probablemente rinde más que todo el esfuerzo de WhisperKit para la mayoría de los casos, dejando WhisperKit solo como tier premium para acentos difíciles.

---

## 6. Priorización

| Prioridad | Acción | Impacto sobre el síntoma |
|---|---|---|
| 🔴 Alta | Fase 1, puntos 1–3 (brecha de reinicio, modo de audio, config del request) | Directo: ataca "se queda corto" (H1) y "no reconoce bien" (H2/H3) en el motor que corre hoy |
| 🟠 Media | Fase 0 (harness + baseline WER) | Indirecto pero necesario para validar cualquier cambio |
| 🟠 Media | Fase 3 (SpeechAnalyzer iOS 26) | Elimina la causa raíz H1 de forma definitiva |
| 🟡 Baja (por ahora) | Fase 2 (WhisperKit) | Hoy no aporta nada — probablemente ni arranca en dispositivo por W1 |

**Conclusión:** WhisperKit es la apuesta correcta de largo plazo para acentos, pero en su estado actual no está contribuyendo al producto. La vía rápida para mejorar el reconocimiento esta semana es la Fase 1.
