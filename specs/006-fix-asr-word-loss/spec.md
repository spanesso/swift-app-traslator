# Feature Specification: Reconocimiento de voz sin pérdida de palabras

**Feature Branch**: `006-fix-asr-word-loss`
**Created**: 2026-07-14
**Status**: Draft
**Input**: Corregir la pérdida de palabras y el reconocimiento deficiente del ASR documentados en `INFORME-DIAGNOSTICO-ASR.md`. Que la app deje de "quedarse corta" y de perder palabras al reconocer voces, especialmente con hablantes acentuados, voz baja o distancia del micrófono.

## Overview

Los usuarios reportan que la app **falla al reconocer las voces**: a veces "se queda corta" (pierde el inicio de las frases tras una pausa) y a veces "no reconoce bien" las palabras (transcripción imprecisa, sobre todo con acento). El informe diagnóstico identificó que la causa no es única: existen defectos estructurales en los tres motores de reconocimiento (ASR), y el más grave —pérdida física de audio en cada reinicio del reconocedor— afecta al motor que corre hoy en la mayoría de los dispositivos.

Esta feature aborda el problema en capas de prioridad: primero medir para no volar a ciegas, luego arreglar el motor que la gente usa hoy (máximo retorno), después hacer viable el motor premium para acentos, y finalmente adoptar el reconocedor de nueva generación que elimina la causa raíz de forma definitiva.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - No perder palabras al retomar el habla (Priority: P1)

Una persona dicta, hace una pausa natural (para respirar o pensar) y retoma. Hoy, cada vez que el reconocedor emite un resultado "final" —lo cual ocurre en cada pausa y también automáticamente cada ~60 segundos— la app reinicia el reconocimiento y **pierde el audio capturado durante ese reinicio**. El inicio de la siguiente frase desaparece sistemáticamente.

**Why this priority**: Es la causa directa del síntoma "se queda corta" y afecta al motor que corre hoy en la mayoría de los dispositivos. Es el arreglo de mayor retorno e impacto inmediato.

**Independent Test**: Se puede validar de forma aislada leyendo un guion conocido con pausas deliberadas cada 10–15 s y una sesión que supere los 60 s, luego comparando la transcripción contra el texto original: ninguna palabra dicha inmediatamente después de una pausa o del corte de ~60 s debe faltar.

**Acceptance Scenarios**:

1. **Given** una sesión de dictado activa, **When** el hablante hace una pausa y retoma en menos de 1 segundo, **Then** la primera palabra tras la pausa aparece en la transcripción.
2. **Given** una sesión continua de más de 60 segundos, **When** el reconocedor alcanza su límite interno y se reinicia, **Then** no se pierde ninguna palabra en el punto de reinicio.
3. **Given** un guion de referencia leído en voz alta, **When** termina la sesión, **Then** la tasa de palabras faltantes atribuibles a reinicios es cero.

---

### User Story 2 - Reconocer bien voz con acento, baja o lejana (Priority: P1)

El público objetivo incluye hablantes con acento, que hablan bajo o a cierta distancia del micrófono. Hoy la captura de audio está configurada para "instrumentación" (desactiva ganancia automática y reducción de ruido) y el reconocedor no recibe pistas de que se trata de dictado, degradando la precisión de forma evitable.

**Why this priority**: Es la causa directa del síntoma "no reconoce bien las palabras" y afecta a todo el público objetivo del proyecto. Junto con la US1, ataca los dos síntomas reportados en el motor actual.

**Independent Test**: Se puede validar leyendo un mismo pasaje con voz normal, voz baja y a ~1 metro del micrófono, y verificando que la transcripción mantiene precisión aceptable en las tres condiciones (mejora medible respecto al comportamiento actual).

**Acceptance Scenarios**:

1. **Given** un hablante que dicta en voz baja, **When** habla a volumen conversacional bajo, **Then** las palabras se reconocen con precisión comparable a la voz normal.
2. **Given** un hablante con acento no nativo, **When** dicta frases completas, **Then** la transcripción incluye puntuación coherente y la sesión no se marca erróneamente como "baja calidad".
3. **Given** respuestas cortas de una sola palabra ("Yes", "Okay"), **When** se pronuncian aisladas, **Then** aparecen en la transcripción y no se descartan.

---

### User Story 3 - Medir la calidad antes y después de cada cambio (Priority: P2)

El equipo necesita saber, con números, si un cambio mejora o empeora el reconocimiento, desglosado por grupo de acento. Hoy no existe un baseline y toda mejora es anecdótica.

**Why this priority**: Habilitante. Sin medición, ningún arreglo puede validarse objetivamente y hay riesgo de regresiones invisibles. Precede en orden de trabajo a los arreglos, pero su valor de usuario final es indirecto.

**Independent Test**: Ejecutar la evaluación sobre un corpus de referencia por grupos de acento y obtener una tasa de error de palabra (WER) por grupo, reproducible entre corridas.

**Acceptance Scenarios**:

1. **Given** un corpus de audio de referencia con transcripciones correctas, **When** se ejecuta la evaluación, **Then** se obtiene un WER por grupo de acento como baseline registrado.
2. **Given** un cambio en el motor de reconocimiento, **When** se re-ejecuta la evaluación, **Then** la comparación contra el baseline muestra si el WER mejoró o empeoró por grupo.
3. **Given** una sesión en un dispositivo de prueba, **When** arranca la app, **Then** los registros indican de forma inequívoca qué motor de reconocimiento está activo.

---

### User Story 4 - Motor premium para acentos difíciles, usable en vivo (Priority: P3)

Para acentos que el motor del sistema reconoce mal, existe un motor premium (WhisperKit) descargable. Hoy, en su estado actual, probablemente ni siquiera arranca en dispositivo real, la traducción no fluye hasta detener la grabación, y descarta habla acentuada. El usuario que activó este motor debe obtener reconocimiento en vivo, con feedback claro durante la descarga del modelo.

**Why this priority**: Alto valor para el nicho de acentos difíciles, pero hoy no aporta nada al producto y requiere trabajo sustancial. Debe entregarse después de estabilizar el motor principal.

**Independent Test**: En un dispositivo compatible, activar el motor premium, completar la descarga del modelo con progreso visible, dictar un pasaje con acento y ver aparecer la traducción en el panel de español mientras se sigue hablando (no solo al parar).

**Acceptance Scenarios**:

1. **Given** el motor premium seleccionado, **When** el usuario inicia el dictado, **Then** la captura de audio funciona sin fallos y no se silencia.
2. **Given** una sesión activa con el motor premium, **When** el hablante dicta frases completas, **Then** las frases confirmadas aparecen traducidas en vivo, sin esperar a detener la grabación.
3. **Given** el modelo aún no descargado, **When** el usuario selecciona el motor premium, **Then** se muestra el progreso de descarga/preparación y el modelo se precarga antes de grabar, no al presionar grabar.
4. **Given** una sesión larga (30–60 s o más), **When** continúa la transcripción, **Then** el reconocimiento no se congela ni se atrasa acumulativamente.
5. **Given** habla con acento marcado, **When** se dicta, **Then** las palabras legítimas no se suprimen por filtros internos de confianza.

---

### User Story 5 - Reconocedor de nueva generación sin límite de tiempo (Priority: P3)

En dispositivos con el sistema operativo más reciente (iOS 26), existe un reconocedor on-device de nueva generación que no tiene el límite de ~60 s ni requiere reinicios, y transcribe mejor sesiones largas. Adoptarlo elimina de raíz la causa de la pérdida de palabras por reinicio.

**Why this priority**: Elimina definitivamente la causa raíz de la US1 y mejora el long-form, pero depende de hardware/SO reciente y coexiste con los otros motores como fallback. Es la solución de fondo, entregable tras las correcciones inmediatas.

**Independent Test**: En un dispositivo con el SO más reciente, ejecutar una sesión continua de varios minutos con pausas y confirmar que no hay reinicios ni pérdida de palabras, y que la transcripción long-form es coherente.

**Acceptance Scenarios**:

1. **Given** un dispositivo con el SO más reciente, **When** el usuario dicta durante varios minutos sin parar, **Then** no ocurren reinicios de reconocimiento ni pérdida de palabras.
2. **Given** el reconocedor de nueva generación disponible, **When** arranca la app en ese dispositivo, **Then** se selecciona como motor por defecto (Tier 0).
3. **Given** un dispositivo sin soporte, **When** arranca la app, **Then** el sistema recurre de forma transparente a un motor compatible.

---

### Edge Cases

- **Pausa muy corta y retoma inmediato**: la primera palabra tras la pausa debe conservarse (US1).
- **Sesión que cruza el límite de ~60 s a mitad de una frase**: la palabra en el punto de corte no debe perderse ni duplicarse.
- **Enunciado de una sola palabra que nunca llega a "final"**: debe emitirse igualmente y no descartarse.
- **Confianza reportada como 0.0 en resultados parciales**: no debe contaminar la métrica de calidad ni forzar el modo "baja calidad".
- **Primeros milisegundos de la sesión**: las primeras palabras no deben perderse por una condición de carrera al iniciar el motor.
- **Indicador de confianza en la UI**: debe corresponder a la frase que efectivamente representa, no a un segmento distinto.
- **Motor premium sin modelo descargado al presionar grabar**: debe informar y preparar, no fallar en silencio ni bajar cientos de MB en ese instante.
- **Descarga del modelo interrumpida o corrupta**: el sistema debe poder reintentar y no marcar el modelo como instalado si no está utilizable.
- **Hardware que captura audio a una frecuencia distinta a la esperada por el motor**: la captura debe adaptarse sin fallar.
- **Ruido de fondo / silencio prolongado con el motor premium**: no debe generar transcripción inventada (alucinaciones).

## Requirements *(mandatory)*

### Functional Requirements

#### Continuidad del reconocimiento (motor actual — síntoma "se queda corta")

- **FR-001**: El sistema MUST conservar y transcribir todo el audio hablado durante los reinicios internos del reconocedor, de modo que ninguna palabra dicha alrededor de una pausa o del límite de tiempo del reconocedor se pierda.
- **FR-002**: El sistema MUST manejar el reinicio automático que ocurre al alcanzar el límite de duración del reconocedor (~60 s) sin perder ni duplicar palabras en el punto de corte.
- **FR-003**: El sistema MUST asegurar que las primeras palabras del inicio de una sesión se capturen y emitan, sin descartarse por condiciones de arranque del motor.

#### Precisión del reconocimiento (motor actual — síntoma "no reconoce bien")

- **FR-004**: El sistema MUST capturar el audio con el procesamiento de señal del sistema activo (ganancia automática y reducción de ruido) para mejorar la relación señal/ruido con voz baja, acentuada o lejana.
- **FR-005**: El sistema MUST indicar al reconocedor que el contexto es dictado y habilitar la puntuación automática, de modo que la segmentación por frases disponga de la puntuación que necesita.
- **FR-006**: El sistema MUST poder incorporar vocabulario de dominio como pistas contextuales para mejorar el reconocimiento de términos esperados.
- **FR-007**: El sistema MUST excluir la confianza de los resultados parciales (que se reporta como nula) del cálculo de calidad, de modo que la sesión no se marque erróneamente como de baja calidad ni aumente la latencia percibida sin causa real.
- **FR-008**: El sistema MUST emitir los enunciados de una sola palabra, en lugar de descartarlos, cuando representan la respuesta completa del hablante.

#### Medición y observabilidad (habilitante)

- **FR-009**: El sistema MUST proveer una evaluación reproducible que calcule la tasa de error de palabra (WER) sobre un corpus de referencia, desglosada por grupo de acento.
- **FR-010**: El sistema MUST registrar un baseline de WER por grupo de acento antes de aplicar los cambios, para permitir comparar mejoras y detectar regresiones.
- **FR-011**: El sistema MUST registrar de forma inequívoca, al arrancar, qué motor de reconocimiento está activo en el dispositivo.

#### Consistencia de la experiencia

- **FR-012**: El sistema MUST asociar el indicador de confianza mostrado en la interfaz con la frase que realmente representa, no con un segmento distinto.
- **FR-013**: El sistema MUST evitar duplicar de forma visible una misma frase en la salida traducida cuando el motor reemite contexto ya confirmado.
- **FR-014**: El sistema SHOULD consolidar la lógica duplicada entre los dos motores basados en el reconocedor del sistema, para evitar que un mismo defecto reaparezca en dos lugares.

#### Motor premium para acentos difíciles (WhisperKit)

- **FR-015**: El sistema MUST capturar audio para el motor premium en un formato compatible con dicho motor, adaptándose a la frecuencia real del hardware sin fallar la captura.
- **FR-016**: El sistema MUST entregar reconocimiento en vivo con el motor premium, emitiendo frases confirmadas a medida que el hablante avanza, de modo que la traducción aparezca sin esperar a detener la grabación.
- **FR-017**: El sistema MUST mantener el rendimiento del motor premium estable a lo largo de sesiones largas, sin acumular atraso ni congelarse.
- **FR-018**: El sistema MUST gestionar el modelo del motor premium de forma que se prepare y precargue al seleccionar el motor (no al presionar grabar), mostrando el progreso de descarga/preparación en la interfaz.
- **FR-019**: El sistema MUST dejar el modelo del motor premium en un estado efectivamente utilizable antes de marcarlo como instalado, y MUST poder recuperarse de descargas interrumpidas o inconsistentes.
- **FR-020**: El sistema MUST NOT suprimir habla legítima con acento por filtros internos de confianza excesivamente estrictos.
- **FR-021**: El sistema SHOULD preservar el contexto entre ventanas de audio consecutivas para no cortar ni transcribir mal palabras en los bordes de ventana.
- **FR-022**: El sistema SHOULD usar una versión fijada y reproducible del componente del motor premium, en lugar de una referencia móvil.

#### Reconocedor de nueva generación (SO reciente)

- **FR-023**: En dispositivos con el sistema operativo más reciente que lo soporte, el sistema MUST usar el reconocedor on-device de nueva generación como motor por defecto (Tier 0), eliminando el límite de duración y los reinicios.
- **FR-024**: El sistema MUST recurrir de forma transparente a un motor compatible en dispositivos que no soporten el reconocedor de nueva generación.

#### Detección de voz / silencio

- **FR-025**: El sistema MUST clarificar el rol del componente que hoy filtra segmentos, y SHOULD, cuando el motor lo requiera, distinguir voz de silencio a nivel de audio para evitar transcripción inventada sobre silencio o ruido.

### Key Entities *(include if feature involves data)*

- **Segmento de reconocimiento**: unidad de texto reconocido con su estado (parcial/final o hipótesis/confirmado) y su confianza asociada. Es la pieza que fluye desde el motor hacia la segmentación y la traducción.
- **Motor de reconocimiento (ASR)**: componente intercambiable que produce segmentos a partir del audio. Existen variantes: sistema clásico, premium para acentos, y de nueva generación. Solo uno está activo por sesión y debe ser identificable en los registros.
- **Métrica de calidad de sesión**: conjunto de señales (tasa de revisión, estabilidad, confianza, fragmentación) que caracterizan la calidad del reconocimiento y adaptan el comportamiento del segmentador.
- **Resultado de evaluación (WER)**: medida de error de transcripción sobre un corpus de referencia, desglosada por grupo de acento, comparable entre corridas (baseline vs. cambio).
- **Estado de instalación del modelo premium**: representa si el modelo del motor premium está ausente, descargándose (con progreso), o listo y utilizable.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: En un guion de referencia leído con pausas deliberadas y sesiones que superen los 60 s, la pérdida de palabras atribuible a reinicios del reconocedor es del 0 %.
- **SC-002**: La tasa de error de palabra (WER) del motor principal mejora de forma medible respecto al baseline en al menos los grupos de acento no nativo y voz baja.
- **SC-003**: Las respuestas de una sola palabra ("Yes", "Okay") aparecen en la transcripción en el 100 % de los casos de prueba definidos.
- **SC-004**: Existe un baseline de WER por grupo de acento, reproducible entre corridas (misma entrada → mismo resultado), disponible antes de aplicar los cambios.
- **SC-005**: En cualquier dispositivo de prueba, el motor activo se puede identificar de forma inequívoca a partir de los registros al arrancar.
- **SC-006**: El indicador de confianza mostrado corresponde a la frase que representa en el 100 % de los casos observados.
- **SC-007**: Con el motor premium en un dispositivo compatible, la captura de audio funciona sin fallos y la traducción de frases confirmadas aparece en vivo (antes de detener la grabación) en sesiones de al menos 2 minutos sin congelarse.
- **SC-008**: Con el motor premium, la descarga/preparación del modelo muestra progreso visible y el modelo queda precargado antes de la primera grabación.
- **SC-009**: En dispositivos con el SO más reciente compatible, una sesión continua de al menos 5 minutos con pausas no produce reinicios ni pérdida de palabras.
- **SC-010**: Ningún cambio introduce una regresión de WER superior al margen de ruido de la evaluación en ningún grupo de acento respecto al baseline.

## Assumptions

- **Plataforma**: el objetivo de esta feature es iPhone (iOS), conforme al giro de plataforma del feature 005; la documentación heredada que describe macOS no aplica a este trabajo.
- **Idiomas**: se mantiene el par de idiomas actual (inglés → español) del producto; esta feature no introduce un selector de idiomas.
- **Priorización de entrega**: las User Stories 1 y 2 (motor actual) se entregan primero por máximo retorno; la 3 (medición) las habilita y valida; las 4 y 5 (WhisperKit e iOS 26) son posteriores.
- **Corpus de evaluación**: se asume disponible un corpus de referencia con grupos de acento (p. ej. del tipo EdAcc/LibriSpeech) para calcular el WER; el código del harness ya existe y se integra al conjunto de pruebas.
- **Motor premium**: en iPhone solo la variante cuantizada del modelo grande es razonable; se evaluará contra el harness si un modelo menor ofrece un WER aceptable con menor latencia y tamaño, sin que esto bloquee las fases previas.
- **Compatibilidad**: el reconocedor de nueva generación solo está disponible en dispositivos con el SO más reciente que lo soporte; en el resto se usa un motor compatible como fallback.
- **Sin nuevas dependencias de servicios remotos**: todo el reconocimiento es on-device; no se introducen servicios externos ni claves de API.
- **Detección de voz**: aclarar el rol del componente de filtrado actual es parte del alcance; implementar un VAD de audio completo se limita a lo que el motor premium requiera para evitar alucinaciones sobre silencio.

## Out of Scope

- Selector de idiomas o soporte de pares de idiomas adicionales.
- Rediseño visual de la interfaz más allá de corregir la asociación del indicador de confianza y mostrar el progreso de descarga del modelo.
- Persistencia o exportación de transcripciones (cubierto por features previas).
- Soporte para plataformas distintas de iPhone.
