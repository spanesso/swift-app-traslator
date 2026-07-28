# Feature Specification: Resiliencia del pipeline de audio en vivo

**Feature Branch**: `008-fix-audio-pipeline-resilience`
**Created**: 2026-07-28
**Status**: Draft
**Input**: Fase 2 derivada del diagnóstico de Fase 1 documentado en [`DIAGNOSIS_AUDIO_PIPELINE.md`](../../DIAGNOSIS_AUDIO_PIPELINE.md). Síntomas reportados en campo, todos intermitentes: pérdida de fragmentos con habla rápida (S1), pausas que no disparan traducción (S2), transcripción congelada en una frase antigua (S3), congelación total que obliga a reiniciar la app (S4), y exports que no siempre traen ambos idiomas (S5).

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Ver por qué falló una sesión (Priority: P1)

Como responsable de la app, cuando un usuario reporta que "a veces se pierde texto", necesito abrir los logs del dispositivo y determinar en menos de cinco minutos qué ocurrió: qué motor estaba activo, cuántas veces rotó la sesión de reconocimiento, con qué código de error terminó cada rotación, cuántos milisegundos de audio quedaron sin capturar, y cuánto tardó cada traducción.

**Why this priority**: Hoy ninguno de los cinco síntomas puede confirmarse ni descartarse desde los logs. El código de error de terminación de la sesión de reconocimiento no se lee ni se registra en ningún punto, los huecos de audio no se miden, y la profundidad de la cola de traducción no se conoce. Sin este trabajo, cualquier corrección posterior se valida "a ojo" y ninguna de las demás historias puede demostrarse cerrada. Es el habilitador de todo lo demás.

**Independent Test**: Grabar una sesión de 10 minutos en un dispositivo real, forzando manualmente una interrupción y un cambio de auriculares. Exportar el log del dispositivo y verificar que cada evento del ciclo de vida aparece con marca de tiempo monotónica y campos completos, sin necesidad de leer código para interpretarlo.

**Acceptance Scenarios**:

1. **Given** una sesión de grabación activa, **When** la sesión de reconocimiento termina por cualquier motivo, **Then** el log registra el motivo, el dominio y el código de error exactos, la duración de la sesión y el índice de rotación.
2. **Given** una rotación de sesión en curso, **When** se completa, **Then** el log registra los milisegundos exactos durante los que ningún componente estuvo capturando audio.
3. **Given** una frase pendiente de emitir, **When** su temporizador de estabilidad se cancela, **Then** el log registra el motivo de la cancelación y si fue reprogramado.
4. **Given** una frase enviada a traducir, **When** se completa o falla, **Then** el log permite calcular su latencia extremo a extremo y la profundidad de la cola en ese instante.
5. **Given** cualquier evento del sistema de audio (interrupción, cambio de ruta, cambio de configuración), **When** ocurre, **Then** queda registrado con el estado del motor antes y después.

---

### User Story 2 - La transcripción en vivo nunca se queda congelada (Priority: P1)

Como usuario en una reunión, quiero que el panel de transcripción en inglés siga mostrando lo que se está diciendo **en todo momento**, sin importar cuánto lleve hablando la gente ni cuántas veces haya rotado internamente el reconocimiento.

**Why this priority**: Es el síntoma más visible y el más frecuente. Hoy el panel en vivo queda vacío o congelado de forma **determinista** a partir de aproximadamente el primer minuto de reunión, porque el texto ya confirmado de toda la sesión se compara contra el texto de una sesión de reconocimiento que acaba de empezar desde cero. El usuario lo percibe como intermitente solo porque el momento exacto depende de cuánto se haya hablado antes.

**Independent Test**: Hablar de forma continua durante 10 minutos y verificar que el texto en vivo se actualiza sin interrupciones en toda la sesión, cruzando al menos ocho rotaciones internas. No requiere ninguna otra historia.

**Acceptance Scenarios**:

1. **Given** una reunión de 30 minutos con habla continua, **When** el reconocimiento rota internamente, **Then** el texto en vivo continúa actualizándose sin quedarse vacío ni congelado.
2. **Given** una rotación acaba de ocurrir, **When** el hablante dice una frase nueva, **Then** esa frase aparece en el panel en vivo y **no** se duplica en el histórico ya confirmado.
3. **Given** el reconocimiento reinicia su transcripción desde cero, **When** el nuevo texto no continúa el texto confirmado previo, **Then** el sistema lo detecta como reinicio y no descarta silenciosamente el contenido nuevo.
4. **Given** una sesión de 30 minutos ya finalizada, **When** el usuario revisa el histórico, **Then** aparecen todas las frases de la reunión, desde la primera hasta la última.

---

### User Story 3 - Toda pausa del hablante produce una traducción (Priority: P1)

Como usuario, cuando el hablante hace una pausa al terminar una idea, quiero ver la traducción de esa idea en el panel en español en menos de un segundo, siempre, sin excepciones.

**Why this priority**: Es el motivo por el que existe la app. Hoy el temporizador que dispara la emisión se cancela cada vez que el reconocimiento reemite el mismo texto parcial —que es exactamente su comportamiento normal durante una pausa— y no se vuelve a programar. El resultado es que la frase queda retenida indefinidamente y nunca llega a traducirse.

**Independent Test**: Leer un guion de 20 frases con pausas de al menos un segundo entre ellas y verificar que se producen exactamente 20 traducciones. No requiere ninguna otra historia.

**Acceptance Scenarios**:

1. **Given** una frase pendiente de emitir, **When** el hablante calla durante el umbral de silencio configurado, **Then** la frase se emite y entra en la cola de traducción.
2. **Given** el reconocimiento reemite el mismo texto parcial repetidamente durante la pausa, **When** eso ocurre, **Then** la emisión pendiente **no** se retrasa ni se cancela.
3. **Given** una frase que lleva pendiente más que el techo máximo permitido, **When** se alcanza ese techo, **Then** la frase se emite de todos modos, aunque el reconocimiento no haya enviado nada nuevo.
4. **Given** un hablante rápido, **When** habla por encima de las 4 palabras por segundo, **Then** el umbral de silencio **no** se incrementa respecto al de un hablante normal.
5. **Given** una frase corta y completa ("Yes.", "Okay"), **When** el hablante hace una pausa, **Then** se emite y se traduce igual que una frase larga.

---

### User Story 4 - La app solo selecciona motores de reconocimiento que funcionan (Priority: P1)

Como usuario, quiero que la app nunca elija para mi dispositivo un motor de reconocimiento que no produce resultados utilizables, y que pueda ver en todo momento cuál está usando.

**Why this priority**: En los dispositivos que cumplen los requisitos de hardware y tienen el modelo local instalado, la app selecciona hoy un motor que reproduce **los cinco síntomas a la vez**: re-procesa todo el audio acumulado de la sesión en cada ventana de análisis, con lo que la carga crece sin límite hasta congelar la app; y marca todos sus resultados como provisionales, de modo que ninguno llega jamás a la capa de traducción. En esa ruta el panel español permanece vacío toda la reunión y los botones de Guardar y Exportar ni siquiera aparecen. **Decisión de alcance (Q1): en esta fase el motor local se retira de la selección en vez de corregirse.** Su rediseño —ventana deslizante con solapamiento y emisión de segmentos estables— queda para una fase posterior. Así, la Fase 2 se concentra en una única ruta de reconocimiento, verificable de extremo a extremo en cualquier dispositivo.

**Independent Test**: Arrancar la app en un dispositivo que hoy seleccionaría el motor local y verificar que usa la ruta alternativa, que el panel español se llena, y que al detener la grabación los botones de Guardar y Exportar están disponibles.

**Acceptance Scenarios**:

1. **Given** un dispositivo que cumple los requisitos de hardware y tiene el modelo local instalado, **When** la app arranca, **Then** **no** selecciona el motor local y usa la ruta alternativa.
2. **Given** el usuario fuerza manualmente una preferencia de motor en los ajustes, **When** esa preferencia apunta a un motor retirado, **Then** la app usa la ruta alternativa y explica por qué.
3. **Given** cualquier sesión de grabación, **When** el usuario consulta los ajustes o los logs, **Then** puede identificar sin ambigüedad qué motor está en uso.
4. **Given** el motor local está retirado, **When** el usuario abre los ajustes, **Then** la opción aparece como no disponible en esta versión, no como una opción que falla en silencio.
5. **Given** el modelo local ya descargado ocupa espacio en el dispositivo, **When** el motor se retira, **Then** la app no vuelve a ofrecer ni iniciar su descarga mientras esté retirado.
6. **Given** cualquier motor activo, **When** configura el sistema de audio, **Then** aplica el mismo tratamiento de la señal de entrada que el resto (conservando el procesado del sistema, no desactivándolo).

---

### User Story 5 - La app se recupera sola de interrupciones y cambios de audio (Priority: P1)

Como usuario en una reunión, quiero que una alarma, una llamada entrante —**aunque no la conteste ni la rechace**—, el asistente de voz, o conectar y desconectar auriculares no maten la grabación: la app debe reanudar sola en un par de segundos y decirme claramente qué pasó.

**Why this priority**: Elevada de P2 a P1 por decisión explícita del usuario en Q3. Es la causa de la congelación total que obliga a reiniciar la app y perder el tramo. Hoy la app no observa los cambios de ruta de audio ni los cambios de configuración del motor de audio; conectar auriculares deja de entregar audio **sin producir ningún error**, y nadie lo detecta. Y las interrupciones se detectan al empezar pero **nunca al terminar**: la grabación se da por muerta de forma irreversible y se muestra un mensaje de "Permiso requerido" que además es falso. **El caso crítico es el desatendido**: una alarma que suena sola, o una llamada que el usuario deja pasar sin tocar el teléfono, hoy terminan la sesión igual que si la hubiera detenido a propósito, y el usuario descubre la pérdida mucho después.

**Independent Test**: Con una grabación activa, dejar sonar una alarma sin tocarla hasta que se apague sola, dejar pasar una llamada entrante sin contestarla ni rechazarla, invocar al asistente de voz, y conectar y desconectar auriculares. Verificar que en los cuatro casos la grabación sigue activa después, sin intervención del usuario.

**Acceptance Scenarios**:

1. **Given** una grabación activa, **When** llega una interrupción del sistema, **Then** la sesión pasa a un estado **suspendido**, no terminado: el histórico se conserva y la grabación sigue considerándose en curso.
2. **Given** una sesión suspendida por interrupción, **When** la interrupción termina, **Then** la captura se reanuda automáticamente sin ninguna acción del usuario.
3. **Given** una alarma que suena y se apaga sola sin que el usuario la toque, **When** termina, **Then** la grabación se reanuda automáticamente y el tramo posterior se transcribe con normalidad.
4. **Given** una llamada entrante que el usuario ni contesta ni rechaza, **When** deja de sonar, **Then** la grabación se reanuda automáticamente.
5. **Given** una interrupción que se prolonga, **When** el usuario mira la pantalla, **Then** ve que la sesión está pausada por audio del sistema y que se reanudará sola; **no** ve un mensaje de permisos.
6. **Given** una grabación activa, **When** el usuario conecta o desconecta auriculares, **Then** la captura continúa con la nueva ruta de audio sin quedarse muda.
7. **Given** el sistema de audio se reinicia por completo, **When** eso ocurre, **Then** la app reconstruye la captura o informa al usuario de que debe reiniciar la grabación.
8. **Given** una grabación activa, **When** el usuario bloquea la pantalla con la app en primer plano, **Then** la captura continúa (decisión Q3) y al desbloquear el contenido del tramo está presente.
9. **Given** una sesión de 30 minutos con tres interrupciones —al menos una desatendida— y dos cambios de ruta, **When** termina, **Then** el usuario no ha tenido que reiniciar la app ni una sola vez y no falta ningún tramo salvo el estrictamente cubierto por las interrupciones.

---

### User Story 6 - No se pierden palabras cuando el reconocimiento rota (Priority: P2)

Como usuario, quiero que las palabras que digo justo en el instante en que el reconocimiento rota internamente aparezcan en la transcripción, especialmente cuando hablo rápido.

**Why this priority**: Explica la pérdida de fragmentos con habla rápida. Ya existe un mecanismo de arrastre de audio que cubre la mayor parte del hueco, pero queda una ventana no medida en la que ni el reconocimiento ni el arrastre están conectados al micrófono, y el reinicio manual descarta 300 ms de forma determinista. Va en P2 porque el mecanismo base ya existe y el impacto residual es menor que el de las historias P1.

**Independent Test**: Leer en voz alta un texto conocido de cinco minutos a ritmo rápido, cruzando al menos cuatro rotaciones, y comparar la transcripción resultante contra el texto original palabra por palabra.

**Acceptance Scenarios**:

1. **Given** una rotación de sesión, **When** se completa, **Then** ningún intervalo de audio ha quedado sin ser capturado por algún componente.
2. **Given** un texto leído conocido de cinco minutos, **When** se transcribe cruzando al menos cuatro rotaciones, **Then** no falta ninguna palabra respecto al original.
3. **Given** el usuario pulsa el botón de reinicio manual, **When** la escucha se reanuda, **Then** el audio descartado está dentro del mismo límite que en una rotación automática.
4. **Given** una sesión sin rotaciones durante un periodo prolongado, **When** el mecanismo de vigilancia evalúa la actividad, **Then** no fuerza una rotación innecesaria si el reconocimiento está entregando resultados.

---

### User Story 7 - El export siempre trae ambos idiomas, o marca explícitamente el hueco (Priority: P2)

Como usuario, cuando exporto o comparto una conversación, quiero poder saber qué traducción corresponde a qué original, y que cuando falte una traducción esté marcada como tal en vez de desaparecer sin dejar rastro.

**Why this priority**: Explica el síntoma del export incompleto. Hoy la conversación se guarda como dos bloques de texto plano independientes, unidos además con separadores distintos —el inglés con espacios, el español con saltos de línea—, de modo que la correspondencia entre original y traducción es irrecuperable. Cuatro filtros distintos reducen el lado español sin tocar el inglés, y ninguno deja rastro.

**Decisión de alcance (Q2): se conserva el esquema actual de dos bloques de texto y se añade correspondencia posicional más marcadores explícitos.** No hay migración de datos ni entidad de fragmento persistida. La consecuencia directa es que **ambos bloques deben usar el mismo separador y tener el mismo número de líneas**, de modo que la línea *n* del bloque español corresponda a la línea *n* del bloque inglés. Es una garantía por convención de formato, no estructural: queda anotada como deuda técnica reconocida.

**Independent Test**: Grabar una conversación en la que al menos una traducción falle deliberadamente, exportarla, y verificar que ambos bloques tienen el mismo número de líneas y que la línea afectada del bloque español lleva la marca de traducción no disponible.

**Acceptance Scenarios**:

1. **Given** una conversación grabada, **When** el usuario la exporta, **Then** el bloque inglés y el bloque español tienen **el mismo número de líneas**, una por fragmento, en el mismo orden.
2. **Given** un fragmento cuya traducción falló, se descartó por ser demasiado corta, o llegó vacía, **When** el usuario exporta, **Then** la línea correspondiente del bloque español lleva una marca explícita de traducción no disponible.
3. **Given** una conversación guardada, **When** se inspecciona, **Then** el recuento de líneas de ambos bloques coincide exactamente.
4. **Given** el usuario detiene la grabación, **When** hay traducciones en vuelo, **Then** se esperan hasta el timeout definido antes de habilitar el guardado.
5. **Given** el servicio de traducción no está disponible al empezar, **When** eso ocurre, **Then** el usuario es informado antes de acumular una cantidad significativa de transcripción sin traducir.
6. **Given** una conversación en la que no se produjo ninguna traducción, **When** el usuario intenta guardarla, **Then** el sistema lo advierte explícitamente en vez de guardar un lado vacío en silencio.
7. **Given** una conversación guardada con el formato anterior a esta fase, **When** el usuario la abre desde el historial, **Then** se muestra y se exporta sin errores, aunque no ofrezca la garantía de correspondencia.

---

### Edge Cases

- **Silencio prolongado.** ¿Qué ocurre si nadie habla durante varios minutos? La sesión no debe darse por muerta ni acumular una frase pendiente que nunca se emite.
- **Ruido continuo sin habla.** ¿El reconocimiento produce texto espurio que llena el histórico y satura la cola de traducción?
- **Dos hablantes solapados.** ¿La emisión por pausa se dispara con la pausa de uno mientras el otro sigue hablando?
- **Frase que cruza una rotación.** Una frase empezada antes de la rotación y terminada después, ¿se emite entera, partida en dos, o duplicada?
- **Traducción que llega después de detener la grabación.** ¿Se descarta, se añade, o bloquea el guardado?
- **Fallo del modelo de traducción a mitad de sesión.** ¿Se sigue transcribiendo en inglés? ¿El usuario se entera?
- **Almacenamiento lleno.** ¿Qué pasa al guardar una conversación de 30 minutos si el dispositivo no tiene espacio?
- **Reunión muy larga (2 h o más).** ¿El histórico en memoria, que es deliberadamente ilimitado, degrada el rendimiento de la interfaz?
- **Cambio de motor a mitad de sesión.** Si el usuario cambia la preferencia de motor mientras graba, ¿qué ocurre con la sesión en curso?
- **Permisos revocados durante la grabación.** ¿Se distingue de una interrupción del sistema?

## Requirements *(mandatory)*

### Functional Requirements

**Observabilidad (US1)**

- **FR-001**: El sistema MUST registrar el inicio y el fin de cada sesión de reconocimiento con marca de tiempo monotónica, identificador de sesión y motor activo.
- **FR-002**: El sistema MUST registrar, en cada terminación de sesión de reconocimiento, el motivo, y cuando exista un error, su dominio y su código exactos.
- **FR-003**: El sistema MUST medir y registrar los milisegundos durante los cuales ningún componente está capturando audio en cada rotación de sesión.
- **FR-004**: El sistema MUST registrar cada cancelación del temporizador de emisión, con su motivo y si fue reprogramado.
- **FR-005**: El sistema MUST registrar la latencia extremo a extremo de cada traducción y la profundidad de la cola de traducción en ese instante.
- **FR-006**: El sistema MUST registrar todo evento del sistema de audio —interrupción, cambio de ruta, cambio de configuración, reinicio de servicios— con el estado del motor antes y después.
- **FR-007**: El sistema MUST usar una marca de tiempo monotónica, no el reloj de pared, en todos los eventos anteriores.
- **FR-008**: Los registros del punto anterior MUST ser legibles desde las herramientas estándar de diagnóstico del dispositivo sin necesidad de una compilación especial.

**Continuidad de la transcripción en vivo (US2)**

- **FR-009**: El sistema MUST mantener el panel de transcripción en vivo actualizado a lo largo de toda la sesión, con independencia del número de rotaciones internas.
- **FR-010**: El sistema MUST detectar cuándo el reconocimiento ha reiniciado su transcripción desde cero y reconciliar su estado de presentación en consecuencia.
- **FR-011**: El sistema MUST NOT descartar texto entrante por comparación contra un estado confirmado acumulado que el reconocimiento ya no puede reproducir.
- **FR-012**: El sistema MUST conservar el histórico completo de la sesión, sin recortes por antigüedad ni por cantidad.

**Emisión por pausa (US3)**

- **FR-013**: El sistema MUST emitir toda frase pendiente no vacía tras el umbral de silencio configurado, con independencia de cuántas veces el reconocimiento haya reemitido el mismo texto durante esa pausa.
- **FR-014**: El sistema MUST NOT dejar una frase pendiente sin emitir por encima de un techo máximo de retención, evaluado por un reloj independiente del flujo de entrada.
- **FR-015**: El sistema MUST usar el mismo umbral de silencio con independencia de la velocidad del hablante.
- **FR-016**: El sistema MUST emitir frases cortas y completas con el mismo criterio que las largas.

**Motor de reconocimiento (US4)**

- **FR-017**: El sistema MUST NOT seleccionar el motor de reconocimiento local en esta fase, con independencia del hardware del dispositivo y de si el modelo está instalado.
- **FR-018**: El sistema MUST usar la ruta de reconocimiento alternativa en todos los dispositivos soportados.
- **FR-019**: El sistema MUST reflejar en la interfaz de ajustes que el motor local no está disponible en esta versión, en vez de ofrecerlo como una opción que falla en silencio.
- **FR-020**: El sistema MUST NOT ofrecer ni iniciar la descarga del modelo local mientras el motor esté retirado.
- **FR-021**: El usuario MUST poder consultar qué motor está en uso, tanto desde los ajustes como desde los logs.
- **FR-022**: Todos los motores presentes en el código MUST configurar el sistema de audio de forma coherente entre sí, conservando el procesado de señal del sistema en vez de desactivarlo.

**Resiliencia de audio (US5)**

- **FR-023**: Una interrupción del sistema MUST poner la sesión en estado **suspendido**, no terminado. El histórico de la sesión MUST conservarse y la grabación MUST seguir considerándose en curso.
- **FR-024**: El sistema MUST reanudar la captura automáticamente cuando la interrupción termina, **sin requerir ninguna acción del usuario**, incluidas las interrupciones que el usuario nunca atiende (alarma que se apaga sola, llamada no contestada ni rechazada).
- **FR-025**: El sistema MUST mostrar el estado de suspensión por audio del sistema de forma explícita mientras dure, indicando que se reanudará automáticamente.
- **FR-026**: El sistema MUST detectar los cambios de ruta de audio y reconstruir la captura con la configuración nueva.
- **FR-027**: El sistema MUST detectar los cambios de configuración del motor de audio y reconstruir la captura.
- **FR-028**: El sistema MUST detectar el reinicio de los servicios de medios y reconstruir la captura o informar al usuario.
- **FR-029**: Los mensajes mostrados al usuario MUST describir la causa real; el sistema MUST NOT reportar un problema de permisos cuando la causa es una interrupción de audio.
- **FR-030**: El sistema MUST liberar la sesión de audio cuando la grabación termina de verdad, y MUST NOT liberarla durante una suspensión.
- **FR-031**: El sistema MUST tener un mecanismo de vigilancia que detecte la ausencia de resultados y fuerce la recuperación, activo para **todos** los motores, no solo para uno.
- **FR-032**: El sistema MUST mantener la captura activa mientras el dispositivo esté bloqueado y la app siga siendo la aplicación en primer plano (decisión Q3).
- **FR-033**: Si el sistema operativo suspende la captura pese a lo anterior, el sistema MUST detectarlo e informar al usuario en vez de perder el tramo en silencio.

**Continuidad del audio en la rotación (US6)**

- **FR-034**: El sistema MUST mantener algún componente capturando audio en todo instante durante una rotación de sesión.
- **FR-035**: El sistema MUST aplicar el mismo criterio de continuidad al reinicio manual iniciado por el usuario que a la rotación automática.
- **FR-036**: El mecanismo de vigilancia MUST considerar la actividad real del reconocimiento, no solo el tiempo transcurrido desde la última rotación.

**Integridad del export (US7)**

- **FR-037**: El sistema MUST conservar el formato de persistencia actual —un bloque de texto por idioma— sin migración de datos (decisión Q2).
- **FR-038**: Ambos bloques MUST usar el mismo separador de fragmento y contener **el mismo número de líneas**, una por fragmento, en el mismo orden, de modo que la correspondencia sea posicional.
- **FR-039**: El sistema MUST insertar una marca explícita de traducción no disponible en la línea correspondiente cuando la traducción de un fragmento falle, se descarte o llegue vacía. El sistema MUST NOT omitir la línea.
- **FR-040**: El sistema MUST aplicar el mismo criterio de deduplicación a ambos idiomas, de modo que un fragmento descartado en un lado lo sea también en el otro.
- **FR-041**: El sistema MUST esperar a las traducciones en vuelo, hasta un timeout definido, antes de habilitar el guardado.
- **FR-042**: El sistema MUST advertir al usuario si el servicio de traducción no está disponible, antes de acumular una cantidad significativa de transcripción sin traducir.
- **FR-043**: El sistema MUST advertir al usuario al guardar una conversación en la que un lado esté vacío.
- **FR-044**: El sistema MUST seguir mostrando y exportando sin errores las conversaciones guardadas con el formato anterior a esta fase, aunque no ofrezcan la garantía de correspondencia posicional.

### Key Entities

- **Sesión de grabación**: el periodo entre que el usuario pulsa grabar y pulsa detener. Contiene múltiples sesiones de reconocimiento y produce una conversación. Puede estar **activa**, **suspendida** (interrupción de audio en curso) o **terminada**. La suspensión es nueva en esta fase y es lo que impide que una alarma desatendida mate la sesión.
- **Sesión de reconocimiento**: una rotación interna del reconocedor. Tiene identificador, instante de inicio, instante y motivo de fin, y un índice de rotación dentro de la sesión de grabación. **Es invisible para el usuario y debe seguir siéndolo.**
- **Fragmento de conversación**: la unidad lógica de emparejamiento. Existe **solo en memoria durante la sesión** (decisión Q2): al persistir se aplana a una línea en cada uno de los dos bloques de texto. Lleva texto original, texto traducido o marca de ausencia, y confianza de la fuente.
- **Conversación**: lo que se persiste y se exporta. Dos bloques de texto —uno por idioma— con el mismo número de líneas, más el instante de guardado. Sin marca de tiempo por fragmento ni etiqueta de idioma por línea: deuda técnica reconocida y aceptada en esta fase.
- **Evento de telemetría**: registro con marca de tiempo monotónica, identificador de sesión, tipo de evento y campos propios del tipo.
- **Evento del sistema de audio**: interrupción (inicio y fin, atendida o no), cambio de ruta, cambio de configuración o reinicio de servicios, con el estado del motor antes y después.

## Success Criteria *(mandatory)*

### Continuidad del audio

- **SC-001**: En una sesión de 30 minutos, el percentil 99 del hueco de captura durante las rotaciones no supera los **50 ms**.
- **SC-002**: En una sesión de 30 minutos no se produce **ningún** hueco de captura superior a 50 ms.
- **SC-003**: El audio descartado en un reinicio manual iniciado por el usuario no supera los **50 ms** (línea base actual: al menos 300 ms).
- **SC-004**: Un texto leído conocido de cinco minutos, que cruce al menos cuatro rotaciones, se transcribe **sin omitir ninguna palabra**.

*Justificación del umbral:* un fonema en inglés conversacional dura 80–100 ms y la palabra funcional más corta ronda los 150 ms. Un hueco por debajo de 50 ms no puede eliminar un fonema completo, luego no puede alterar el reconocimiento.

### Recuperación ante eventos de audio

- **SC-005**: Tras el fin de una interrupción del sistema, la captura se reanuda en **2 000 ms** o menos.
- **SC-006**: El **100 %** de las interrupciones desatendidas —alarma que se apaga sola, llamada no contestada ni rechazada— terminan con la sesión reanudada automáticamente, **sin ninguna acción del usuario**.
- **SC-007**: **Cero** interrupciones del sistema terminan la sesión de grabación de forma irreversible.
- **SC-008**: Tras un cambio de ruta de audio, la captura continúa con la configuración nueva en **1 000 ms** o menos.
- **SC-009**: En una sesión de 30 minutos con tres interrupciones —al menos una desatendida— y dos cambios de ruta, el usuario **no necesita reiniciar la app ni una sola vez**.
- **SC-010**: **Ningún** evento de audio produce un mensaje de permisos salvo una denegación real de permisos.
- **SC-011**: Con el dispositivo bloqueado y la app en primer plano, una sesión de **10 minutos** se transcribe completa, sin tramos ausentes.

*Justificación de los umbrales:* una llamada no contestada o una invocación del asistente duran 1–3 s y el hablante suele repetir la última frase, de modo que reanudar en 2 s deja la pérdida dentro de lo que el contexto absorbe. Un corte de más de 1 s por cambio de auriculares se come una frase entera a ritmo conversacional (≈2,5 palabras/s). SC-006 y SC-007 son los criterios que traducen la corrección pedida explícitamente en Q3: hoy el 100 % de las interrupciones, atendidas o no, matan la sesión sin retorno.

### Emisión y traducción

- **SC-012**: Tras **800 ms** de silencio, el **100 %** de las frases pendientes no vacías han sido emitidas.
- **SC-013**: **Ninguna** frase pendiente permanece retenida más de **3 000 ms**.
- **SC-014**: Un guion con 20 pausas de al menos un segundo produce **exactamente 20** traducciones.
- **SC-015**: El percentil 95 de la latencia de traducción no supera los **1 500 ms** y la profundidad de la cola no supera los **3** elementos.

*Justificación de los umbrales:* las pausas dentro de una frase se concentran en 200–500 ms y las pausas entre frases superan los 700 ms; bajar de 600 ms parte frases por la mitad y subir de 1 000 ms introduce latencia perceptible. Los 800 ms son el umbral actual de 700 ms más holgura de planificación. Los 3 000 ms de techo duro son el límite superior de una pausa retórica larga: más allá de eso, retener texto ya no es esperar, es perder.

### Estabilidad sostenida

- **SC-016**: Una sesión de 30 minutos se completa con **cero** congelaciones y **cero** reinicios manuales de la app.
- **SC-017**: La memoria residente se mantiene estable dentro de un **±10 %** entre el minuto 5 y el minuto 30.
- **SC-018**: En 30 minutos de habla continua, el mecanismo de vigilancia **no** se dispara por falsa inactividad.
- **SC-019**: En **cero** de los dispositivos soportados la app selecciona el motor de reconocimiento local.

*Justificación:* 30 minutos es la duración mínima de la reunión real que motiva la app, y supone más de 30 rotaciones internas — suficiente para que cualquier fuga acumulativa se manifieste. Los criterios sobre carga de análisis por ventana desaparecen respecto al borrador inicial: al retirarse el motor local (Q1), la causa que medían deja de estar en el producto. Vuelven en la fase que lo reincorpore.

### Integridad del export

- **SC-020**: El bloque inglés y el bloque español de una conversación exportada tienen **el mismo número de líneas**, siempre.
- **SC-021**: El **100 %** de los fragmentos sin traducción llevan una marca explícita en su línea; **cero** huecos silenciosos.
- **SC-022**: Al menos el **98 %** de las líneas exportadas tienen traducción real, no marca de ausencia.
- **SC-023**: Las traducciones en vuelo al detener la grabación se drenan con un timeout de **3 000 ms**.
- **SC-024**: Si el servicio de traducción no está disponible, el usuario es informado antes de acumular más de **10 s** de transcripción sin traducir.
- **SC-025**: El **100 %** de las conversaciones guardadas antes de esta fase siguen abriéndose y exportándose sin error.

*Justificación del 98 %:* el servicio de traducción falla legítimamente en algunos casos (fragmentos sin contexto, ruido transcrito como texto); exigir el 100 % obligaría a enmascarar esos fallos con contenido inventado. Los requisitos duros son SC-020 y SC-021: un hueco marcado es auditable, un hueco invisible no.

### Diagnóstico en campo

- **SC-026**: Ante un reporte de fallo, la causa raíz se identifica desde los logs del dispositivo en **5 minutos** o menos, sin leer código fuente.
- **SC-027**: El **100 %** de las terminaciones de sesión de reconocimiento quedan registradas con su código de error exacto.
- **SC-028**: Los cinco síntomas originales (S1–S5) pueden confirmarse o descartarse a partir de una única sesión de log de 10 minutos.

## Decisiones de alcance resueltas

| # | Decisión | Elección | Consecuencia |
|---|---|---|---|
| Q1 | Motor de reconocimiento local | **Retirarlo de la selección** en esta fase | US4 se reduce a desactivar y comunicar. Los criterios de carga por ventana desaparecen. Su rediseño (ventana deslizante con solapamiento, emisión de segmentos estables) se pospone a una fase posterior. Una única ruta de reconocimiento que validar. |
| Q2 | Modelo de datos persistido | **Conservar dos bloques de texto, añadir marcadores** | Sin migración de datos. La correspondencia original↔traducción pasa a ser **posicional por número de línea**, garantizada por formato y no por estructura. Deuda técnica reconocida: sin marca de tiempo por fragmento y sin etiqueta de idioma por línea. |
| Q3 | Comportamiento en segundo plano | **Seguir capturando con la pantalla bloqueada y la app en primer plano**, más recuperación obligatoria de interrupciones desatendidas | US5 sube de P2 a P1. Una alarma o una llamada no atendidas ya **no** pueden terminar la sesión: la suspenden y se reanuda sola. En iOS, mantener la captura con el dispositivo bloqueado exige declarar el modo de audio en segundo plano, con el impacto correspondiente en batería y en la ficha de la tienda. |

## Assumptions

- El objetivo es corregir el comportamiento existente, no rediseñar la arquitectura. La separación en capas actual y la selección de motor por preferencia se mantienen.
- **Sobre Q3:** la opción elegida (capturar con pantalla bloqueada y app en primer plano) converge en la práctica con habilitar el modo de audio en segundo plano, porque iOS no distingue "bloqueado con la app delante" de "en segundo plano" a efectos de captura de micrófono. La planificación debe asumir ese cambio de configuración y su justificación ante la revisión de la tienda. Se deja explícito aquí porque se advirtió al decidir y se optó por seguir adelante.
- **Sobre Q2:** la garantía de correspondencia por número de línea es frágil ante cualquier cambio futuro de formato. Es una decisión deliberada de coste, no un descuido. Si más adelante se quiere marca de tiempo por fragmento o intercalado real, habrá que migrar entonces.
- **Sobre Q1:** el modelo local ya descargado en dispositivos de usuarios permanece en disco. Esta fase no lo borra ni lo usa.
- El par de idiomas sigue siendo inglés a español. No entra un selector de idiomas en esta fase.
- La transcripción y la traducción siguen siendo en el dispositivo. No se introduce ningún servicio remoto.
- El umbral de silencio de 700 ms se conserva como valor; el trabajo consiste en garantizar que se dispare siempre, no en cambiarlo.
- El mecanismo de arrastre de audio existente se conserva y se corrige; no se sustituye.
- El histórico ilimitado en memoria dentro de una sesión, decidido en la feature 007, se mantiene: no se reintroduce ningún recorte por cantidad.
- Los criterios se validan en dispositivo físico. El simulador no reproduce el comportamiento del sistema de audio ni de las interrupciones.
- Al retirarse el motor local, **todos** los criterios se validan en la única ruta de reconocimiento activa, en cualquier dispositivo soportado. Ya no hace falta hardware específico para cerrar la fase.
- Las interrupciones desatendidas (SC-006) se validan con una alarma real del sistema y una llamada entrante real, no con simulaciones; el comportamiento del sistema al no atenderlas es precisamente lo que se está corrigiendo.
- No se añaden dependencias externas.
- Los cambios sin commitear de las features 006 y 007 forman la línea base de esta fase.
