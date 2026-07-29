# Feature Specification: Fiabilidad en reuniones largas

**Feature Branch**: `009-long-session-reliability`
**Created**: 2026-07-28
**Status**: Draft
**Input**: Los cinco riesgos abiertos identificados tras validar la feature 008 en dispositivo. Cuatro salen directamente de los logs de campo del 2026-07-28; el quinto es una promesa que 008 hizo y nunca comprobó.

## Contexto

La feature 008 corrigió los cinco síntomas reportados y quedó verificada en dispositivo para lo que el usuario notaba. Al revisar sus logs aparecieron cinco problemas que **el usuario todavía no ha sufrido pero que el sistema ya está produciendo**, todos ligados a la duración de la reunión o a condiciones que aún no se han probado.

Ninguno es una regresión de 008. Cuatro son observaciones nuevas sobre código que ya existía; el quinto es deuda de validación que 008 dejó explícitamente abierta.

| # | Evidencia | Historia |
|---|---|---|
| 1 | `UIBackgroundModes: audio` declarado en 008 (decisión Q3), nunca verificado con pantalla bloqueada | US1 |
| 2 | `[TR_DONE] frag=25 translateMs=3939` frente a ~80 ms típicos | US2 |
| 3 | `[SESSION_END] reason=error errDomain=kAFAssistantErrorDomain errCode=1110` | US3 |
| 4 | El texto confirmado se acumula y se re-examina en cada actualización parcial (~3/s) | US4 |
| 5 | `[AUDIO_GAP] gapMs=1100 expectedMs=100` con `evicted=21`, sin causa atribuida | US5 |

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Grabar con la pantalla bloqueada funciona de verdad (Priority: P1)

Como usuario en una reunión de una hora, bloqueo la pantalla para ahorrar batería y espero que la app siga transcribiendo. Si el sistema no me lo permite, quiero enterarme **en el momento**, no al final cuando falte media hora de conversación.

**Why this priority**: la feature 008 declaró el modo de audio en segundo plano y verificó que la **captura** continúa — pero nunca comprobó que el **reconocimiento de voz** sobreviva. Son cosas distintas: el sistema puede seguir entregando audio y a la vez suspender la tarea de reconocimiento. Si eso ocurre, la app estaría grabando en silencio, produciendo nada, y el usuario lo descubriría al desbloquear. Es la promesa central de la decisión Q3 y hoy es una suposición.

**Independent Test**: grabar, bloquear la pantalla, hablar 30 minutos, desbloquear, y comparar la transcripción contra lo dicho. No requiere ninguna otra historia.

**Acceptance Scenarios**:

1. **Given** una grabación activa, **When** el usuario bloquea la pantalla y sigue hablando 30 minutos, **Then** la transcripción contiene ese tramo completo.
2. **Given** una grabación con la pantalla bloqueada, **When** el sistema suspende el reconocimiento pese al modo declarado, **Then** el usuario recibe un aviso perceptible en menos de 10 segundos.
3. **Given** que el reconocimiento fue suspendido por el sistema, **When** el usuario desbloquea la pantalla, **Then** ve con claridad qué tramo falta, en vez de un hueco silencioso.
4. **Given** una grabación con la pantalla bloqueada, **When** llega una interrupción del sistema y termina, **Then** la sesión se reanuda igual que con la pantalla encendida.
5. **Given** que el reconocimiento no puede sobrevivir al bloqueo en este sistema, **When** el usuario inicia una grabación, **Then** el comportamiento es el definido en la Clarificación Q1.

---

### User Story 2 - Una frase lenta no retrasa a las siguientes (Priority: P1)

Como usuario siguiendo la traducción en vivo, quiero que una frase difícil no congele el panel español para todo lo que venga detrás.

**Why this priority**: las traducciones se resuelven de una en una. En los logs de campo, una tardó **3 939 ms** frente a los ~80 ms habituales, y todo lo encolado detrás esperó. En una conversación fluida eso son varias frases retenidas por una sola lenta, justo el efecto de "voy perdiendo el hilo" que motivó la feature 008.

**Independent Test**: encolar una frase deliberadamente lenta seguida de tres cortas y medir cuánto tarda cada una desde que se encola hasta que aparece. No requiere ninguna otra historia.

**Acceptance Scenarios**:

1. **Given** una frase que tarda 4 segundos en traducirse, **When** llegan tres frases cortas detrás, **Then** esas tres aparecen sin esperar a que termine la lenta.
2. **Given** varias traducciones resolviéndose a la vez, **When** aparecen en pantalla, **Then** cada una ocupa la posición que le corresponde por orden de habla, no por orden de llegada.
3. **Given** una traducción que se resuelve después que otra posterior, **When** eso ocurre, **Then** la presentación sigue lo definido en la Clarificación Q2.
4. **Given** una ráfaga de frases, **When** se procesan, **Then** el sistema no lanza trabajo sin límite: hay un tope de traducciones simultáneas.
5. **Given** que el usuario detiene la grabación con varias traducciones en vuelo, **When** se drena la cola, **Then** el comportamiento de espera y marcado de 008 se conserva sin cambios.

---

### User Story 3 - Una pausa larga no cuenta como fallo (Priority: P2)

Como responsable de la app, quiero que el registro distinga "nadie habló" de "algo se rompió", para no perder tiempo persiguiendo errores que no lo son.

**Why this priority**: el sistema de reconocimiento informa "no se detectó habla" con un código de error. La app lo trata como fallo y fuerza un reinicio de la sesión de reconocimiento. En una reunión con silencios eso es **comportamiento normal**, no una avería. Cada reinicio innecesario descarta la línea base de segmentación, infla el contador de reinicios y ensucia el registro — el mismo registro sobre el que se apoya todo el diagnóstico de campo de 008.

**Independent Test**: grabar, callar 30 segundos, seguir hablando; comprobar que no se registró ningún reinicio por error y que la transcripción continúa.

**Acceptance Scenarios**:

1. **Given** una grabación activa, **When** nadie habla durante 30 segundos, **Then** no se registra ninguna terminación de sesión por error.
2. **Given** una pausa prolongada, **When** el hablante retoma, **Then** la transcripción continúa sin haber perdido la línea base de segmentación.
3. **Given** un fallo real del reconocimiento, **When** ocurre, **Then** sí se registra como error con su código, y sí provoca la recuperación correspondiente.
4. **Given** una sesión de 30 minutos con silencios naturales, **When** se revisa el registro, **Then** el número de reinicios refleja causas reales y no el ritmo de la conversación.

---

### User Story 4 - Una reunión de dos horas se comporta como una de diez minutos (Priority: P2)

Como usuario en una reunión larga, quiero que la app responda igual de bien en el minuto 110 que en el minuto 10.

**Why this priority**: el texto ya confirmado se acumula durante toda la sesión y se vuelve a examinar en cada actualización del reconocedor, unas tres veces por segundo. El coste por actualización crece con la duración de la reunión. En diez minutos no se nota; en dos horas es trabajo real y creciente sobre la ruta que alimenta la interfaz. Va en P2 porque nadie lo ha sufrido todavía — pero es exactamente el perfil del defecto que aparece cuando más caro cuesta.

**Independent Test**: sesión de 2 horas midiendo el tiempo de procesamiento por actualización y la memoria en el minuto 10 y en el minuto 110.

**Acceptance Scenarios**:

1. **Given** una sesión de 2 horas, **When** se compara el minuto 110 con el minuto 10, **Then** el tiempo de procesamiento por actualización se mantiene dentro de un ±10 %.
2. **Given** una sesión de 2 horas, **When** se compara el consumo de memoria, **Then** se mantiene dentro de un ±10 % entre ambos momentos.
3. **Given** una sesión larga, **When** el usuario se desplaza por el histórico, **Then** la interfaz responde igual que al principio.
4. **Given** una sesión larga, **When** termina, **Then** el histórico completo sigue disponible para guardar y exportar, sin recortes.

---

### User Story 5 - Todo hueco de audio tiene una causa conocida (Priority: P2)

Como responsable de la app, cuando el sistema informe de una interrupción en la captura quiero saber **por qué** ocurrió, no solo que ocurrió.

**Why this priority**: la feature 008 introdujo la detección de huecos de audio y funcionó — detectó uno de 1,1 segundos con 21 descartes del búfer de arrastre. Pero el registro dice que hubo un hueco y nada más. Sin atribución, un hueco es indistinguible de otro: presión de CPU, apagado en curso, cambio de dispositivo o un fallo de verdad se ven exactamente igual. Es un enfoque a medio hacer: se mide el síntoma sin capturar el contexto que lo explica.

**Independent Test**: sesión de 30 minutos; comprobar que cada hueco registrado lleva una causa atribuida y que las causas son distinguibles entre sí.

**Acceptance Scenarios**:

1. **Given** una interrupción en la captura de audio, **When** se registra, **Then** lleva una causa atribuida además de su duración.
2. **Given** un hueco que coincide con el apagado de la sesión, **When** se registra, **Then** queda marcado como esperado y no como anomalía.
3. **Given** un hueco sin causa identificable, **When** se registra, **Then** queda marcado explícitamente como no atribuido, en vez de asignarle una causa inventada.
4. **Given** una sesión de 30 minutos, **When** se revisa el registro, **Then** el alcance de esta historia es el definido en la Clarificación Q3.

---

### Edge Cases

- **Llamada entrante con la pantalla bloqueada.** ¿La reanudación automática de 008 sigue funcionando cuando el usuario ni siquiera ve la pantalla?
- **Batería agotándose durante una reunión larga.** ¿El sistema entra en modo de bajo consumo y suspende la app? ¿El usuario se entera?
- **Reunión de más de dos horas.** ¿Hay algún límite práctico y está declarado?
- **Traducción que nunca termina.** Con varias en paralelo, ¿una colgada bloquea un hueco de la cola indefinidamente?
- **Silencio de varios minutos** (la reunión se pausa de verdad). ¿Se distingue de un fallo del micrófono?
- **Bloqueo de pantalla justo durante una interrupción.** Dos transiciones a la vez.
- **Almacenamiento lleno** al guardar una conversación de dos horas.

## Requirements *(mandatory)*

### Functional Requirements

**Captura con la pantalla bloqueada (US1)**

- **FR-001**: El sistema MUST verificar que el reconocimiento de voz sigue produciendo resultados con la pantalla bloqueada, no solo que la captura de audio continúa.
- **FR-002**: El sistema MUST detectar que el reconocimiento dejó de producir resultados mientras la grabación se considera activa, y MUST informar al usuario de forma perceptible en 10 segundos o menos.
- **FR-003**: El sistema MUST dejar constancia visible del tramo afectado cuando el reconocimiento se haya suspendido, en vez de presentar un histórico con un hueco silencioso.
- **FR-004**: La recuperación ante interrupciones definida en la feature 008 MUST comportarse igual con la pantalla bloqueada que con la pantalla encendida.
- **FR-005**: El comportamiento cuando el reconocimiento no puede sobrevivir al bloqueo se resolverá según [NEEDS CLARIFICATION: Q1 — ¿qué hacemos si iOS suspende el reconocimiento pese al modo de audio en segundo plano?].

**Cola de traducción (US2)**

- **FR-006**: El sistema MUST permitir que varias traducciones se resuelvan a la vez, de modo que una lenta no retenga a las siguientes.
- **FR-007**: El sistema MUST limitar el número de traducciones simultáneas; MUST NOT lanzar trabajo sin cota bajo una ráfaga.
- **FR-008**: Cada traducción MUST aparecer en la posición que le corresponde por orden de habla, con independencia del orden en que se resuelva.
- **FR-009**: La presentación de una traducción que se resuelve fuera de orden se definirá según [NEEDS CLARIFICATION: Q2 — ¿se muestra el hueco mientras llega, o se retiene la salida hasta poder mostrarla en orden?].
- **FR-010**: El drenaje al detener la grabación y el marcado de traducciones no disponibles introducidos en la feature 008 MUST conservarse sin cambios.

**Clasificación de terminaciones (US3)**

- **FR-011**: El sistema MUST distinguir "no se detectó habla" de un fallo del reconocimiento.
- **FR-012**: Una ausencia de habla MUST NOT provocar un reinicio de la sesión de reconocimiento ni descartar la línea base de segmentación.
- **FR-013**: Un fallo real MUST seguir registrándose con su código y MUST seguir provocando la recuperación correspondiente.
- **FR-014**: El registro MUST permitir contar reinicios por causa, de modo que una reunión con muchos silencios no se confunda con una sesión inestable.

**Coste sostenido (US4)**

- **FR-015**: El coste de procesar una actualización del reconocedor MUST NOT crecer con la duración de la sesión.
- **FR-016**: El consumo de memoria MUST mantenerse estable a lo largo de una sesión larga.
- **FR-017**: El sistema MUST conservar el histórico completo de la sesión disponible para guardar y exportar; MUST NOT introducir ningún recorte por cantidad (decisión de la feature 007).
- **FR-018**: La interfaz MUST responder al desplazamiento por el histórico igual en el minuto 110 que en el minuto 10.

**Atribución de huecos (US5)**

- **FR-019**: Todo hueco de captura registrado MUST llevar una causa atribuida junto a su duración.
- **FR-020**: Los huecos esperados —los que coinciden con el apagado o el arranque de una sesión— MUST quedar marcados como tales y MUST NOT contarse como anomalías.
- **FR-021**: Un hueco sin causa identificable MUST marcarse explícitamente como no atribuido.
- **FR-022**: El alcance de esta historia se resolverá según [NEEDS CLARIFICATION: Q3 — ¿instrumentar y medir, o instrumentar y comprometerse a corregir la causa dentro de esta fase?].

### Key Entities

- **Motivo de terminación de sesión**: por qué acabó una sesión de reconocimiento. Hoy solo distingue "final", "error" y "parada del usuario"; necesita separar la ausencia de habla del fallo real.
- **Trabajo de traducción**: una frase esperando traducción. Tiene posición de habla —que fija dónde aparece— e instante de encolado y de resolución, que hoy no se distinguen entre sí.
- **Hueco de captura**: una interrupción en el flujo de audio. Hoy tiene duración; le falta causa y la clasificación esperado/anómalo.
- **Estado de reconocimiento en segundo plano**: si el sistema sigue produciendo resultados con la pantalla bloqueada. Hoy no se observa en absoluto.

## Success Criteria *(mandatory)*

### Captura con la pantalla bloqueada

- **SC-001**: Una sesión de **30 minutos** con la pantalla bloqueada produce una transcripción **sin tramos ausentes**.
- **SC-002**: Si el reconocimiento se suspende, el usuario recibe un aviso perceptible en **10 segundos** o menos.
- **SC-003**: El **100 %** de los tramos perdidos por suspensión quedan señalados en el histórico; **cero** huecos silenciosos.
- **SC-004**: Una interrupción del sistema con la pantalla bloqueada se reanuda dentro del mismo umbral de **2 000 ms** que fijó la feature 008.

*Justificación:* 30 minutos es la duración mínima de la reunión real que motiva la app, y es tiempo de sobra para que el sistema decida suspender una tarea en segundo plano. Los 10 segundos de aviso son el máximo que puede pasar sin que el usuario, al mirar el teléfono, ya haya perdido contexto suficiente para no poder recuperarlo de memoria.

### Cola de traducción

- **SC-005**: Con una frase que tarda **4 segundos**, las tres siguientes aparecen en **1 500 ms** o menos desde que se encolan.
- **SC-006**: El percentil 95 de la espera en cola no supera los **500 ms**.
- **SC-007**: Las traducciones simultáneas **nunca** superan el tope configurado, ni siquiera con una ráfaga de 10 frases.
- **SC-008**: El **100 %** de las traducciones aparecen en la posición correspondiente a su orden de habla.

*Justificación:* los 1 500 ms de SC-005 son el umbral por debajo del cual el lector no percibe que algo se atascó. El p95 de espera en cola de 500 ms separa "el servicio tardó" de "estuvo esperando su turno": son problemas distintos y hoy son indistinguibles porque la espera ni se mide.

### Clasificación de terminaciones

- **SC-009**: Una pausa de 30 segundos produce **cero** reinicios de sesión de reconocimiento.
- **SC-010**: En una sesión de 30 minutos con silencios naturales, el **100 %** de los reinicios registrados corresponden a causas reales.
- **SC-011**: Los fallos reales siguen registrándose con su código: **cero** pérdidas de información de diagnóstico respecto a la feature 008.

### Coste sostenido

- **SC-012**: En una sesión de **2 horas**, el tiempo de procesamiento por actualización se mantiene dentro de un **±10 %** entre el minuto 10 y el minuto 110.
- **SC-013**: La memoria residente se mantiene dentro de un **±10 %** entre esos mismos dos momentos.
- **SC-014**: El histórico completo de las 2 horas sigue disponible para guardar y exportar.
- **SC-015**: **Cero** congelaciones o reinicios manuales de la app en esas 2 horas.

*Justificación:* dos horas es el doble de la reunión típica y el punto donde un coste que crece linealmente ya se nota. El ±10 % es el mismo margen que fijó la feature 008 para 30 minutos; sostenerlo al cuádruple de duración es la prueba real de que el coste dejó de crecer.

### Atribución de huecos

- **SC-016**: El **100 %** de los huecos registrados llevan una causa atribuida o la marca explícita de no atribuido.
- **SC-017**: **Cero** huecos esperados aparecen contados como anomalías.
- **SC-018**: Ante un hueco reportado desde campo, su causa se identifica desde el registro en **5 minutos** o menos, sin leer código fuente.

*Justificación:* SC-018 es el mismo criterio que fijó la feature 008 para el diagnóstico de sesiones; extenderlo a los huecos de audio cierra el único punto del registro que hoy dice "pasó algo" sin decir qué.

## Assumptions

- La feature 008, tal como quedó tras la validación en dispositivo del 2026-07-28, es la línea base. Ninguno de estos cinco puntos es una regresión suya.
- Las decisiones de alcance de la feature 008 se mantienen: el motor de reconocimiento local sigue retirado, el modelo persistido no migra, y el histórico dentro de una sesión sigue sin recortes.
- El par de idiomas sigue siendo inglés a español. Transcripción y traducción siguen en el dispositivo.
- **Sin dependencias nuevas.**
- Todo se valida en dispositivo físico. El simulador no reproduce la suspensión en segundo plano, ni las interrupciones, ni el comportamiento térmico — es decir, nada de lo que aquí importa.
- La medición de US4 requiere una sesión real de 2 horas. No hay atajo: un test sintético no reproduce ni la presión térmica ni el ritmo real del reconocedor.
- La identificación de hablantes (colorear el texto por persona) **no forma parte de esta feature**. Se evaluó por separado y depende de una medición previa de las marcas de tiempo por palabra.

## Fuera de alcance

Explícitamente **no** entran aquí, aunque se detectaron en la misma revisión:

- Retirar el código muerto encontrado (registro de calidad de sesión que nunca se persiste, ventana de contexto de traducción sin usar, filtro de segmentos vacíos que perdió su motivo, corrector que casi nunca se dispara, dependencia del motor local aún enlazada).
- Las mejoras de interfaz: el desplazamiento automático que pelea con el usuario, el emparejamiento visual entre los dos idiomas, la selección de texto.
- La identificación de hablantes.

Son válidas y están registradas, pero mezclarlas con cinco riesgos de fiabilidad haría que ninguna de las dos cosas se pudiera validar por separado.
