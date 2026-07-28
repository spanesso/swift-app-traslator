# Quickstart — Validación en dispositivo

**Feature**: 008-fix-audio-pipeline-resilience
**Fecha**: 2026-07-28

Cómo comprobar que la fase está cerrada. **Todo se valida en iPhone o iPad físico.** El simulador no reproduce el comportamiento de `AVAudioSession` ni las interrupciones reales, que es justo lo que se está corrigiendo.

---

## 0. Antes de tocar nada — capturar la línea base

Se hace **una sola vez, con el código actual sin modificar**. Sin este paso no hay con qué comparar y cualquier mejora es una impresión.

```bash
# En una terminal, con el dispositivo conectado
log stream --device --predicate 'subsystem == "com.spanesso.TraslatorApp"' --style compact | tee baseline.log
```

Grabar 10 minutos de habla continua y anotar:

| Medida | Cómo obtenerla del log | Valor actual esperado |
|---|---|---|
| Motor en uso | línea `[Container] engine=` | `legacySFSpeech` o `whisperKitTurbo` |
| Rotaciones | contar `🔄 [Speech] Restarting` | ~10 en 10 min con reconocimiento por servidor |
| ¿El panel EN se congela? | observación visual | **sí**, sobre el minuto 1 |
| ¿Las pausas traducen? | contar `[TRANSLATE-START]` frente a pausas reales | menos traducciones que pausas |
| Alineación del export | exportar y contar líneas de cada bloque | recuentos distintos |

Guardar `baseline.log`. Es la referencia de los 28 criterios de éxito.

---

## 1. US1 — Telemetría

```bash
log stream --device --predicate 'subsystem == "com.spanesso.TraslatorApp" AND category == "Telemetry"' --style compact
```

Grabar 10 min, forzando una interrupción y un cambio de auriculares.

- [ ] **SC-027** — Todo `[SESSION_END]` lleva `errDomain=` y `errCode=` cuando `reason=error`. Cero excepciones.
- [ ] **SC-026** — Con solo este log, alguien que no conozca el código explica en ≤5 min por qué terminó cada sesión.
- [ ] **SC-028** — Los cinco síntomas se confirman o descartan desde una sola captura de 10 min.
- [ ] Cada evento lleva un instante monotónico que **avanza durante el bloqueo de pantalla** (research R3).
- [ ] Ningún evento de telemetría contiene texto transcrito.

**Filtros útiles**

```bash
grep '\[SESSION_END\]'  telemetry.log | awk '{print $4, $5}' | sort | uniq -c   # motivos y códigos
grep '\[TAP_SWAP\]'     telemetry.log | grep -v 'blindMs=0'                     # debe salir VACÍO
grep '\[STAB_CANCEL\]'  telemetry.log | grep 'rescheduled=false'                # debe salir VACÍO
```

Las dos últimas líneas son la prueba directa de US6 y US3. Si devuelven algo, el defecto sigue vivo.

---

## 2. US2 — La transcripción en vivo no se congela

**El escenario que hoy falla de forma determinista.**

1. Grabar y hablar sin parar **10 minutos**.
2. Vigilar el panel inglés en el minuto 1, el 3, el 5 y el 10.

- [ ] **SC-016** — El texto en vivo se actualiza en los cuatro momentos. Nunca queda vacío ni congelado.
- [ ] Tras cada rotación, la frase nueva aparece y **no** se duplica en el histórico gris.
- [ ] Al terminar, el histórico contiene la reunión completa, desde la primera frase.
- [ ] `grep '\[UI_PREFIX_MISMATCH\]' | grep 'branch=wordCount'` no aparece de forma sostenida.

**Prueba unitaria que debe existir** (sin hardware): reconciliador con 300 palabras confirmadas, rotación, entran 4 palabras → devuelve esas 4, no `""`. Es la regresión exacta de S3.

---

## 3. US3 — Toda pausa traduce

Leer en voz alta un guion de **20 frases** con pausas de ≥1 s entre ellas.

- [ ] **SC-014** — Aparecen **exactamente 20** traducciones. Ni 19 ni 21.
- [ ] **SC-012** — Cada una aparece antes de 800 ms desde el fin de la frase.
- [ ] **SC-013** — Ninguna frase tarda más de 3 000 ms.
- [ ] **SC-015** — Repetir el guion a ritmo rápido (>4 palabras/s): siguen siendo 20, y `[STAB_ARMED]` sigue mostrando `reason=normal`, no `lowQuality`.

Frases cortas de control, que deben traducirse igual: `"Yes."` `"Okay."` `"Right."`

---

## 4. US4 — Motor local retirado

- [ ] **SC-019** — En un dispositivo A17 Pro+ con el modelo instalado, el log muestra `engine=appleSFSpeech`. Nunca `whisperKitTurbo`.
- [ ] Con la preferencia guardada en "Enhanced Accuracy", la app usa igualmente la ruta Apple y lo explica.
- [ ] Los ajustes muestran la opción deshabilitada, no como una opción que falla en silencio.
- [ ] La app no ofrece ni inicia la descarga del modelo local.
- [ ] Con `requiresOnDeviceRecognition = true` (research R1), las rotaciones **caen drásticamente**: comparar el recuento de `[RESTART_BEGIN]` contra `baseline.log`.

---

## 5. US5 — Resiliencia de audio

**El bloque más importante y el que más manos requiere: son eventos reales del sistema, no simulables.**

### 5a. Interrupción atendida
1. Grabar. 2. Llamarse desde otro teléfono. 3. Rechazar la llamada.
- [ ] **SC-005** — La captura se reanuda en ≤2 000 ms. Verificar con `[AUDIO_INTERRUPTION]`.
- [ ] **SC-007** — La sesión pasó a `suspended`, **no** a terminada.

### 5b. Interrupción DESATENDIDA — el requisito que pediste
1. Grabar. 2. Poner una alarma del sistema. 3. **No tocar el teléfono.** 4. Dejar que la alarma se apague sola.
- [ ] **SC-006** — La grabación se reanuda **sola**, sin ninguna acción.
- [ ] El histórico previo a la alarma sigue completo.
- [ ] El tramo posterior se transcribe con normalidad.

Repetir con una llamada entrante que **no** se contesta ni se rechaza.

- [ ] Durante la alarma, la pantalla muestra "en pausa, se reanudará sola". **No** muestra "Permission Required" (**SC-010**).

### 5c. Cambio de ruta
1. Grabar con el micrófono interno. 2. Conectar AirPods hablando. 3. Desconectarlos.
- [ ] **SC-008** — La captura continúa en ≤1 000 ms en ambos sentidos.
- [ ] `[AUDIO_ROUTE_CHANGE]` muestra frecuencias de muestreo distintas antes y después, y `[AUDIO_CONFIG_CHANGE]` muestra `formatsMatch=true` después.

### 5d. Pantalla bloqueada (decisión Q3)
1. Grabar. 2. Bloquear la pantalla. 3. Hablar 10 minutos. 4. Desbloquear.
- [ ] **SC-011** — Los 10 minutos están transcritos, sin tramos ausentes.
- [ ] Las marcas de tiempo de telemetría avanzaron durante el bloqueo (verifica research R3).

### 5e. Sesión larga combinada
30 minutos con tres interrupciones —al menos una desatendida— y dos cambios de ruta.
- [ ] **SC-009** — Cero reinicios manuales de la app.
- [ ] **SC-016** — Cero congelaciones.
- [ ] **SC-017** — Memoria estable ±10 % entre el minuto 5 y el 30 (Instruments → Allocations).
- [ ] **SC-018** — Cero `[WATCHDOG_FIRED]` por falsa inactividad.

---

## 6. US6 — Sin pérdida de palabras en la rotación

Leer un texto conocido de **5 minutos** a ritmo rápido, cruzando al menos cuatro rotaciones.

- [ ] **SC-004** — Comparar palabra por palabra contra el original: **cero omisiones**.
- [ ] **SC-001 / SC-002** — `grep '\[TAP_SWAP\]' | grep -v 'blindMs=0'` sale vacío. Con el tap permanente (research R4) el valor esperado no es "pequeño", es **cero**.
- [ ] **SC-003** — Pulsar "Restart Listening" hablando: el audio descartado es ≤50 ms, no los ≥300 ms actuales.
- [ ] `grep '\[AUDIO_GAP\]'` sale vacío en 30 min (confirma research R5).

---

## 7. US7 — Export íntegro

1. Grabar 20 frases. 2. Provocar al menos un fallo de traducción — activar el Modo Avión a mitad es la forma más simple. 3. Detener, guardar, exportar.

```bash
# Sobre el .txt exportado
awk '/=== ENGLISH/,/=== SPANISH/' export.txt | grep -c .
awk '/=== SPANISH/,0'            export.txt | grep -c .
```

- [ ] **SC-020** — Los dos recuentos coinciden. Siempre.
- [ ] **SC-021** — El fragmento fallido aparece con su inglés y el marcador de no disponible. Cero huecos silenciosos.
- [ ] **SC-022** — Al menos el 98 % de las líneas llevan traducción real.
- [ ] **SC-023** — Al detener con traducciones en vuelo, se drenan hasta 3 000 ms antes de habilitar Guardar.
- [ ] **SC-024** — Con el servicio de traducción caído desde el inicio, el aviso llega antes de 10 s de transcripción.
- [ ] **SC-025** — Una conversación guardada **antes** de esta fase se abre y se exporta sin error.

---

## 8. Puertas del constitution check

- [ ] Compila sin warnings de concurrencia (puerta G5).
- [ ] Ningún archivo Swift nuevo supera 250 líneas (puerta G7); `ContinuousSpeechListener` ya no existe.
- [ ] `grep -r "import AVFoundation" TranslatorApp/Domain/` sale vacío (puerta G2).
- [ ] `grep -r "import SwiftUI" TranslatorApp/Domain/` sale vacío (puerta G2).
- [ ] Cero dependencias nuevas en `project.pbxproj` (puerta G6).
- [ ] Un solo `@unchecked Sendable` nuevo, en `RecognitionRequestBox` (puerta G5, justificado).

---

## Criterio de cierre

La fase está cerrada cuando los 28 criterios de éxito del spec están marcados **con evidencia de log o de medición adjunta**, no por inspección visual. Los tres que más fácilmente se dan por buenos sin comprobar de verdad:

- **SC-006** (interrupción desatendida) — hay que dejar sonar la alarma de verdad, sin tocar el teléfono.
- **SC-004** (cero palabras perdidas) — hay que comparar contra un texto de referencia, no "sonar bien".
- **SC-020** (líneas alineadas) — hay que contar las líneas, no mirar el export por encima.
