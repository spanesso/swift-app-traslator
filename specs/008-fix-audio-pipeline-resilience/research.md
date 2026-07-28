# Phase 0 — Research

**Feature**: 008-fix-audio-pipeline-resilience
**Fecha**: 2026-07-28

Siete decisiones técnicas que la implementación necesita cerradas. Cada una en formato Decisión / Justificación / Alternativas.

---

## R1 — Reconocimiento en el dispositivo frente a reconocimiento por servidor

**Contexto.** `requiresOnDeviceRecognition` **no se fija en ningún punto del repo** (cero ocurrencias, verificado en Fase 1). Su valor por defecto es `false`, de modo que con red disponible el reconocimiento es por servidor. Ese es exactamente el modo sujeto al límite de duración de audio de aproximadamente un minuto y a fallos de red — es decir, **la app está hoy por omisión en la configuración que causa la rotación constante** que a su vez origina S1 y S3.

**Decisión.** Fijar `requiresOnDeviceRecognition = true`, previa comprobación de `supportsOnDeviceRecognition`, con degradación a servidor solo si el dispositivo no lo soporta.

**Justificación.**

- Elimina el límite de duración por sesión, que es la causa raíz de la rotación periódica. Menos rotaciones significa menos oportunidades de perder audio (US6) y de desincronizar la vista (US2).
- Elimina la dependencia de red, y con ella una clase entera de errores intermitentes que hoy son indistinguibles porque el código de error no se lee.
- Es coherente con la promesa del producto: el resto del pipeline —traducción, corrector— ya es en el dispositivo.
- El deployment target de iOS 26.1 garantiza soporte en dispositivo en todo el hardware alcanzado.

**Consecuencia que hay que aceptar.** El reconocimiento en dispositivo tiene históricamente algo menos de precisión que el de servidor con habla acentuada — precisamente el escenario que motivó la feature 005. **Se mide, no se asume**: la telemetría de US1 registra la confianza por token, de modo que la comparación es empírica. Si la degradación resulta inaceptable, la decisión se revierte con datos y la rotación se mantiene con el resto de correcciones de US6 intactas, que son valiosas de todos modos.

**Alternativas consideradas.**

- *Mantener servidor y limitarse a rotar mejor.* Rechazada como opción por defecto: deja viva la causa raíz y hace depender una app de reuniones de la conectividad. Sigue siendo el plan B si la precisión cae.
- *Selección dinámica según la red.* Rechazada: dos modos de comportamiento duplican la superficie de validación de todos los criterios de US6 sin beneficio claro.

---

## R2 — Semántica de reanudación tras interrupción, incluidas las desatendidas

**Contexto.** Es el requisito que el usuario añadió explícitamente: una alarma que se apaga sola o una llamada que nadie contesta hoy terminan la sesión igual que un stop deliberado (`DependencyContainer.swift:115-125` → `TranscriptionViewModel.swift:126-131`). No existe rama de fin de interrupción en todo el repo.

**Decisión.** Máquina de tres estados con reanudación por notificación **más sondeo de respaldo**:

1. Al recibir el inicio de la interrupción: la sesión pasa a **suspendida**. Se detiene el motor de audio pero **no** se desactiva la sesión de audio, no se cierra el stream y no se limpia el histórico.
2. Al recibir el fin de la interrupción: si el sistema indica que se puede reanudar, se reactiva la sesión de audio y se reconstruye la captura.
3. **Respaldo**, porque el paso 2 no está garantizado: mientras el estado sea suspendido, un temporizador intenta reactivar la sesión de audio cada 2 s. El éxito de la reactivación es la señal real de que la interrupción terminó. Se abandona tras 60 s consecutivos de fallo, informando al usuario.

**Justificación.** La notificación de fin de interrupción no se entrega de forma fiable en todos los casos — notoriamente cuando otra app se queda con la sesión de audio, o cuando el sistema considera que la interrupción no es reanudable. Depender solo de ella reproduce el mismo fallo con distinta forma. El sondeo convierte "esperar un evento que quizá no llegue" en "comprobar una condición que sí es observable". Los 2 s de cadencia son un compromiso entre cumplir SC-005 (reanudar en ≤2 000 ms) y no gastar batería sondeando.

**Punto fino sobre el caso desatendido.** Una alarma que sigue sonando mantiene la interrupción activa: el sondeo fallará repetidamente y eso es correcto — la sesión debe seguir suspendida, no darse por muerta. En cuanto la alarma se apaga sola, el siguiente sondeo tiene éxito y la captura se reanuda. Ese es exactamente el comportamiento que se pidió.

**Alternativas consideradas.**

- *Solo la notificación de fin.* Rechazada: es la solución de manual y falla justo en el caso que motivó el requisito.
- *Solo sondeo.* Rechazada: añade hasta 2 s de latencia innecesaria cuando la notificación sí llega, y SC-005 exige 2 000 ms totales.
- *Pedir al usuario que reanude manualmente.* Rechazada: contradice literalmente FR-024.

---

## R3 — Reloj monotónico para medir huecos

**Contexto.** SC-001 a SC-003 exigen medir huecos de audio en milisegundos, y el código actual usa `DispatchTime.now().uptimeNanoseconds` (`EmptySegmentFilter.swift:26`).

**Decisión.** Usar `ContinuousClock` para toda la telemetría y para las ventanas de tiempo del pipeline. Sustituir el uso actual de `uptimeNanoseconds` en `EmptySegmentFilter`.

**Justificación.** `DispatchTime.uptimeNanoseconds` **se detiene mientras el dispositivo está dormido**. Con la decisión Q3 —capturar con la pantalla bloqueada— eso deja de ser un detalle: una medición de hueco que abarque un periodo de suspensión daría un valor menor que el real, y precisamente en el escenario que Q3 introduce. `ContinuousClock` sigue avanzando durante la suspensión y es lo que corresponde a "cuánto tiempo real pasó". `SuspendingClock` tiene la semántica contraria y sería el error clásico aquí. `Date` queda descartado por ser reloj de pared: un ajuste horario produciría deltas negativos.

**Alternativas consideradas.**

- *`mach_continuous_time()` directo.* Equivalente en semántica, peor en ergonomía y en pruebas. `ContinuousClock` es su envoltorio de biblioteca estándar.
- *`Date`.* Rechazada, ver arriba.

---

## R4 — Continuidad del tap frente a cambios de ruta

**Contexto.** Dos requisitos que a primera vista chocan. US6 quiere un tap **permanente**, instalado una sola vez por sesión de grabación, para eliminar la ventana ciega de la rotación. US5 exige reaccionar a cambios de ruta, que cambian el formato del nodo de entrada y por tanto **obligan** a reinstalar el tap.

**Decisión.** Separar los dos ejes por su causa:

- **Rotación del reconocimiento** (frecuente, interna, invisible): el tap **no se toca**. El closure escribe en un contenedor de request intercambiable; rotar es sustituir un puntero. Ventana ciega cero por construcción, no por medición.
- **Cambio de ruta o de configuración** (poco frecuente, externo, observable): se reconstruye la captura entera —parar el motor, reinstalar el tap con el formato nuevo, arrancar— dentro del presupuesto de 1 000 ms de SC-008. El búfer de arrastre cubre el hueco.

**Justificación.** El error del diseño actual es tratar ambos casos con el mismo mecanismo: reinstalar el tap en cada rotación, que es lo frecuente, para poder manejar el cambio de formato, que es lo raro. Invertir esa relación elimina el coste del caso frecuente y deja el caso raro con el único mecanismo que realmente lo resuelve. El formato solo cambia cuando cambia la ruta, y eso es observable.

**Nota de implementación.** El motor de audio debe leer el formato del nodo de entrada **en el momento de instalar el tap**, nunca desde un valor cacheado. El defecto actual es exactamente ese: el formato se lee una vez (`ContinuousSpeechListener.swift:83`) y se reutiliza indefinidamente.

**Alternativas consideradas.**

- *Reinstalar el tap en cada rotación, pero más rápido.* Rechazada: optimiza una ventana que puede eliminarse por completo, y deja el hueco dependiendo de la carga del sistema.
- *Nodo de mezcla intermedio con formato fijo.* Rechazada: añade una conversión de formato en la ruta de captura, más superficie y más latencia, para resolver algo que el contenedor intercambiable ya resuelve.

---

## R5 — Copia sin asignación de memoria en el hilo de render

**Contexto.** El closure del tap llama hoy a `AudioRingBuffer.append`, que asigna un `AVAudioPCMBuffer` nuevo por cada buffer entrante (`AudioRingBuffer.swift:66-81`). Asignar memoria en un callback de audio en tiempo real puede bloquear de forma no acotada. El comentario del archivo justifica el lock pero no la asignación.

**Decisión.** Preasignar en el arranque de la sesión un anillo de buffers de tamaño fijo dimensionado para la ventana de 1,5 s, y que el tap solo copie muestras (`memcpy`) sobre un slot ya existente. Sin asignación, sin liberación, sin crecimiento de colecciones en el hilo de render. El lock se mantiene, pero pasa a proteger solo dos índices enteros.

**Justificación.** Es la corrección estándar para una ruta de audio en tiempo real y no cambia la interfaz del componente: `append` y `drain` conservan su forma. El coste es reservar memoria fija por adelantado — a 48 kHz mono en coma flotante, 1,5 s son unos 288 KB. Irrelevante frente al beneficio.

**Punto de honestidad.** El diagnóstico de Fase 1 marcó esto con confianza **media**: el mecanismo es real pero su magnitud nunca se midió. La telemetría de US1 mide los huecos entre buffers consecutivos, así que el efecto será observable. Si resulta que no contribuía, la corrección sigue siendo correcta por sí misma y su coste es despreciable.

**Alternativas consideradas.**

- *Dejarlo como está.* Rechazada: es trabajo con asignación en un hilo de tiempo real, incorrecto con independencia de si hoy se manifiesta.
- *Cola sin locks de un productor y un consumidor.* Rechazada por ahora: mayor complejidad para un lock que, ya reducido a dos enteros, no es el cuello de botella. Reconsiderable si la telemetría muestra contención.

---

## R6 — `SpeechAnalyzer` como alternativa al motor actual

**Contexto.** `IPHONEOS_DEPLOYMENT_TARGET = 26.1`. `SpeechAnalyzer` y `SpeechTranscriber` están disponibles en **todos** los dispositivos soportados. `SFSpeechRecognizer` es la API anterior. Además, `AppleSpeechAnalyzerEngine` está mal nombrado: promete `SpeechAnalyzer` y entrega `SFSpeechRecognizer` (`AppleSpeechAnalyzerEngine.swift:17,37,101`).

**Decisión. No migrar en esta fase.** Se documenta como el candidato de la fase siguiente y se deja el diseño preparado para ello.

**Justificación.**

- El spec fija explícitamente el alcance: *"corregir el comportamiento existente, no rediseñar la arquitectura"* y *"el mecanismo de arrastre de audio existente se conserva y se corrige; no se sustituye"*.
- Migrar el motor invalidaría los criterios de US6 en el momento de escribirlos: `SpeechAnalyzer` está diseñado para audio continuo de larga duración y **no impone el límite de sesión que obliga a rotar**. Sin rotación no hay ventana ciega que medir.
- Una sola fase que retira un motor (Q1) y sustituye otro deja el producto sin ninguna ruta de reconocimiento validada.

**Lo que hay que decir con claridad.** Esta es la decisión con más potencial de invalidar trabajo de la fase. Si se migrase a `SpeechAnalyzer`, **US6 completa y la parte de reconciliación de US2 dejarían de tener objeto**, porque la rotación —su causa— desaparecería. US1, US3, US5 y US7 son independientes del motor y se conservan íntegras en cualquier caso.

**Preparación que sí se hace ahora, y que no cuesta nada de más.** La consolidación en `AppleSFSpeechEngine` detrás del `SpeechEngineProtocol` existente deja la sustitución futura como añadir una implementación del protocolo y cambiar una línea del selector. `AudioCaptureSession` es agnóstico del reconocedor y se reutiliza tal cual.

**Alternativas consideradas.**

- *Migrar ahora.* Rechazada por alcance, y porque combinada con Q1 dejaría cero motores validados.
- *Migrar en paralelo, tras un flag.* Rechazada: dos rutas de reconocimiento duplican la validación de los 28 criterios de éxito.

---

## R7 — Formato de telemetría legible desde el dispositivo

**Contexto.** SC-026 exige identificar la causa raíz desde los logs del dispositivo en cinco minutos o menos, sin leer código fuente. El proyecto ya usa OSLog con subsistema `com.spanesso.TraslatorApp` y una categoría por componente.

**Decisión.** Conservar OSLog. Añadir la categoría `Telemetry`. Cada evento se emite en una línea con un prefijo de tipo estable y pares `clave=valor`:

```
[SESSION_END] sid=A1B2 engine=appleSFSpeech reason=error errDomain=kAFAssistantErrorDomain errCode=203 durMs=61240 restartIdx=7
[TAP_SWAP]    sid=A1B2 restartIdx=7 blindMs=0 carryBuffers=0
[STAB_CANCEL] sid=A1B2 reason=duplicateText rescheduled=true tailWords=6 pendingMs=430
```

**Justificación.**

- Un prefijo estable y en mayúsculas permite filtrar por tipo de evento con una sola búsqueda de texto, tanto en la consola como en un volcado exportado. Es lo que hace posible el objetivo de cinco minutos.
- Los pares clave-valor se leen a simple vista y se extraen con herramientas de línea de comandos sin analizador propio.
- OSLog ya está en uso, no añade dependencias y respeta la puerta G9.
- Un identificador de sesión corto —los primeros cuatro caracteres del UUID— basta para correlacionar y no llena la línea.

**Descartado explícitamente.** JSON por línea: más pesado, ilegible en la consola en vivo, y sin ninguna ventaja mientras nadie ingiera estos logs automáticamente. Si algún día hace falta, la conversión desde pares clave-valor es trivial.

**Nota sobre privacidad.** Los eventos de telemetría **no incluyen texto transcrito**, solo recuentos y medidas. El contenido de las frases ya se registra en los `Logger` existentes con otras categorías, cuyo comportamiento no se cambia en esta fase.

---

## Resumen de decisiones

| # | Decisión | Requisitos que desbloquea |
|---|---|---|
| R1 | Reconocimiento en el dispositivo, con degradación a servidor | FR-034, US6, y elimina la causa de la rotación frecuente |
| R2 | Suspender y reanudar con notificación más sondeo de respaldo | FR-023, FR-024, SC-005, SC-006, SC-007 |
| R3 | `ContinuousClock` en telemetría y ventanas del pipeline | FR-007, y correcto bajo la decisión Q3 |
| R4 | Tap permanente para la rotación; reconstrucción solo por cambio de ruta | FR-026, FR-027, FR-034, SC-001, SC-002 |
| R5 | Anillo preasignado, copia sin asignación en el hilo de render | SC-002 |
| R6 | No migrar a `SpeechAnalyzer` en esta fase; dejarlo preparado | Acota el alcance; ver riesgo R1 del plan |
| R7 | OSLog con categoría `Telemetry`, prefijo de tipo y pares clave-valor | FR-001…FR-008, SC-026, SC-028 |

**Cero marcadores NEEDS CLARIFICATION pendientes.**
