# Feature Specification: Durabilidad del texto de la reunión

**Feature Branch**: `develop`
**Created**: 2026-07-28
**Status**: Draft
**Input**: Pérdida real de datos reportada en campo el 2026-07-28: el usuario perdió la transcripción y la traducción del inicio de una reunión.

## El problema

El texto de la reunión —transcripción y traducción— **vive únicamente en memoria** hasta que el usuario pulsa Guardar. No se escribe en ningún sitio antes de ese momento.

Tres formas de destruirlo, verificadas en el código:

| # | Cómo se pierde | Evidencia |
|---|---|---|
| 1 | Pulsar el botón de grabar otra vez borra la sesión anterior sin confirmación | `TranscriptionViewModel+Session.swift:44-47` |
| 2 | La app puede detenerse sola (fin de stream, o 60 s sin poder reactivar el audio); el usuario vuelve a pulsar grabar y ahí se pierde | `TranscriptionViewModel+Session.swift:39` y `:70` |
| 3 | iOS mata la app en segundo plano por presión de memoria — más probable desde que la feature 008 habilitó el modo de audio en segundo plano | — |

Además, al detener la grabación los botones visibles son Guardar, Exportar **y** el de grabar. Uno preserva y otro destruye, sin ninguna señal que los distinga.

**Reconocimiento explícito:** la feature 008 se dedicó íntegramente a no perder *audio* —búfer de arrastre, tap permanente, telemetría de huecos de milisegundos— y nunca cuestionó que el *texto*, que es el producto, no tuviera ninguna durabilidad. Se midió lo fácil de medir en vez de lo que importaba.

**Esta feature es bloqueante para publicar en tiendas.** Una app de reuniones que puede perder la reunión no es publicable.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Nada de lo transcrito se pierde jamás (Priority: P1)

Como usuario grabando una reunión, quiero que cada frase quede a salvo en el instante en que aparece, sin depender de que yo recuerde pulsar nada.

**Why this priority**: es el problema. Todo lo demás en esta feature existe para sostenerlo.

**Independent Test**: grabar 5 minutos, matar la app desde el selector de apps sin pulsar Guardar, reabrirla y comprobar que el contenido está.

**Acceptance Scenarios**:

1. **Given** una grabación activa, **When** se confirma una frase, **Then** queda persistida antes de que aparezca la siguiente.
2. **Given** una grabación activa, **When** el usuario fuerza el cierre de la app, **Then** al reabrirla se conserva todo salvo, como mucho, la última frase en curso.
3. **Given** una grabación activa, **When** el sistema mata la app en segundo plano, **Then** el resultado es el mismo que en el escenario anterior.
4. **Given** una grabación con la pantalla bloqueada, **When** se confirma una frase, **Then** también queda persistida — el cifrado del dispositivo no puede impedir la escritura.
5. **Given** una frase ya persistida, **When** llega su traducción, **Then** la traducción también queda persistida.
6. **Given** una traducción que falla, **When** se marca como no disponible, **Then** esa marca también queda persistida: se recupera el estado real, no un hueco.

---

### User Story 2 - Recuperar una reunión interrumpida (Priority: P1)

Como usuario cuya app se cerró a mitad de una reunión, al reabrirla quiero encontrar lo que ya se había transcrito, no una pantalla en blanco.

**Why this priority**: persistir sin poder recuperar no resuelve nada. US1 y US2 son la misma promesa vista desde los dos lados.

**Independent Test**: forzar el cierre a mitad de sesión, reabrir, y comprobar que se ofrece la recuperación con el contenido íntegro y en orden.

**Acceptance Scenarios**:

1. **Given** una sesión que quedó sin cerrar, **When** el usuario abre la app, **Then** se le informa de que hay una reunión sin terminar y se le ofrece recuperarla.
2. **Given** una sesión recuperada, **When** se muestra, **Then** las frases aparecen en el orden en que se dijeron y con su traducción o su marca de no disponible.
3. **Given** una sesión recuperada, **When** el usuario la guarda o exporta, **Then** funciona igual que una sesión normal.
4. **Given** una sesión recuperada, **When** el usuario decide descartarla, **Then** se le pide confirmación explícita antes de borrarla.
5. **Given** que el registro quedó cortado a mitad de escritura, **When** se recupera, **Then** se conserva todo lo íntegro y solo se descarta el fragmento incompleto final.
6. **Given** que no hay ninguna sesión pendiente, **When** el usuario abre la app, **Then** no se le muestra nada: la recuperación no puede convertirse en ruido.

---

### User Story 3 - Toda reunión terminada queda archivada sola (Priority: P1)

Como usuario, al detener la grabación quiero que la reunión ya esté guardada, sin tener que acordarme de nada.

**Why this priority**: hoy Guardar es un paso manual y opcional, y el botón que lo destruye está al lado. Depender de la memoria del usuario para no perder el producto es el fallo de diseño, no un detalle de comodidad.

**Independent Test**: grabar, detener, cerrar la app sin pulsar Guardar, abrir el historial y comprobar que la reunión está.

**Acceptance Scenarios**:

1. **Given** una grabación con contenido, **When** el usuario la detiene, **Then** queda archivada automáticamente en el historial.
2. **Given** una reunión ya archivada automáticamente, **When** el usuario pulsa Guardar, **Then** no se crea un duplicado y se le indica que ya está guardada.
3. **Given** una grabación sin ninguna frase, **When** el usuario la detiene, **Then** no se archiva nada: no se ensucia el historial con sesiones vacías.
4. **Given** una reunión archivada automáticamente, **When** el usuario abre el historial, **Then** la encuentra con el mismo formato que una guardada a mano.
5. **Given** que el archivado automático falla, **When** ocurre, **Then** el usuario es informado y el registro de recuperación **no** se borra.

---

### User Story 4 - Empezar una grabación nueva nunca destruye la anterior en silencio (Priority: P2)

Como usuario, si pulso grabar por error teniendo una reunión en pantalla, quiero que la app me detenga, no que la borre.

**Why this priority**: con US3 la reunión anterior ya está archivada, así que esto deja de ser catastrófico y pasa a ser una red de seguridad. Sigue haciendo falta: el histórico en pantalla desaparece y el usuario cree haber perdido algo.

**Independent Test**: grabar, detener, pulsar grabar de nuevo y comprobar que se pide confirmación indicando que la anterior está a salvo.

**Acceptance Scenarios**:

1. **Given** una reunión terminada en pantalla, **When** el usuario pulsa grabar, **Then** se le pide confirmación antes de limpiar la vista.
2. **Given** esa confirmación, **When** se muestra, **Then** indica con claridad que la reunión anterior ya está en el historial.
3. **Given** una pantalla sin contenido, **When** el usuario pulsa grabar, **Then** empieza directamente, sin fricción innecesaria.
4. **Given** un reinicio interno de la escucha, **When** ocurre, **Then** el histórico se conserva sin pedir nada — no es una sesión nueva.

---

### Edge Cases

- **Almacenamiento lleno** al persistir una frase. ¿El usuario se entera de que ha dejado de estar a salvo?
- **Reunión de tres horas**: el registro de recuperación crece. ¿Hay algún límite y está declarado?
- **Dos frases confirmadas casi a la vez**: ¿pueden quedar desordenadas o pisarse en el registro?
- **La app se mata justo entre confirmar la frase y persistirla.** ¿Cuánto es "como mucho la última frase"?
- **Sesión recuperada y luego el usuario pulsa grabar** sin guardarla ni descartarla.
- **Registro de recuperación de una versión anterior de la app** tras actualizar.
- **Pantalla bloqueada desde el arranque del dispositivo** (sin desbloquear nunca): el cifrado puede impedir escribir.

## Requirements *(mandatory)*

### Persistencia continua (US1)

- **FR-001**: El sistema MUST persistir cada frase confirmada en el momento de confirmarse, sin esperar a ninguna acción del usuario.
- **FR-002**: El sistema MUST persistir el resultado de cada traducción —tanto el texto como la marca de no disponible— en el momento de resolverse.
- **FR-003**: La persistencia MUST sobrevivir al cierre forzado de la app, a un fallo de la app y a que el sistema la mate en segundo plano.
- **FR-004**: La persistencia MUST funcionar con el dispositivo bloqueado, siempre que se haya desbloqueado al menos una vez desde el arranque.
- **FR-005**: La persistencia MUST NOT bloquear la interfaz ni la ruta de captura de audio.
- **FR-006**: La pérdida máxima aceptable ante una muerte abrupta MUST ser una sola frase: la que estuviera escribiéndose en ese instante.
- **FR-007**: El sistema MUST avisar al usuario si deja de poder persistir, por ejemplo por falta de espacio.

### Recuperación (US2)

- **FR-008**: Al abrir la app, el sistema MUST detectar si quedó una sesión sin cerrar y ofrecer recuperarla.
- **FR-009**: Una sesión recuperada MUST conservar el orden de las frases y el estado de cada traducción.
- **FR-010**: El sistema MUST tolerar un registro cortado a mitad de escritura: MUST conservar todo lo íntegro y descartar solo el fragmento final incompleto.
- **FR-011**: Una sesión recuperada MUST poder guardarse y exportarse igual que cualquier otra.
- **FR-012**: Descartar una sesión recuperada MUST requerir confirmación explícita.
- **FR-013**: Si no hay sesión pendiente, el sistema MUST NOT mostrar nada al respecto.

### Archivado automático (US3)

- **FR-014**: Al detener una grabación con contenido, el sistema MUST archivarla automáticamente.
- **FR-015**: El sistema MUST NOT crear duplicados si el usuario además pulsa Guardar.
- **FR-016**: El sistema MUST NOT archivar sesiones sin ninguna frase.
- **FR-017**: El registro de recuperación MUST borrarse solo después de un archivado correcto.
- **FR-018**: Si el archivado falla, el sistema MUST informar al usuario y MUST conservar el registro de recuperación.

### Protección ante destrucción (US4)

- **FR-019**: Empezar una grabación nueva con contenido en pantalla MUST requerir confirmación.
- **FR-020**: Esa confirmación MUST indicar si la reunión anterior ya está a salvo.
- **FR-021**: Un reinicio interno de la escucha MUST NOT pedir confirmación ni limpiar el histórico.
- **FR-022**: El sistema MUST NOT descartar contenido transcrito por ninguna vía automática sin dejar rastro.

## Success Criteria *(mandatory)*

- **SC-001**: Cierre forzado de la app a los 5 minutos de grabación: se recupera el **100 %** de las frases confirmadas, salvo como mucho **una**.
- **SC-002**: Muerte de la app en segundo plano con la pantalla bloqueada: mismo resultado que SC-001.
- **SC-003**: **Cero** frases confirmadas se pierden al detener y volver a grabar.
- **SC-004**: El **100 %** de las reuniones detenidas con contenido aparecen en el historial sin que el usuario pulse Guardar.
- **SC-005**: Un registro truncado artificialmente a mitad de línea se recupera conservando el **100 %** de las frases íntegras.
- **SC-006**: Persistir una frase añade **menos de 50 ms** al camino de confirmación, medido en dispositivo.
- **SC-007**: En una sesión de 2 horas, el coste de persistir la frase número 1 000 es el mismo que el de la primera, dentro de un **±10 %**.
- **SC-008**: **Cero** duplicados en el historial tras detener y pulsar Guardar.
- **SC-009**: **Cero** confirmaciones mostradas cuando no hay contenido que proteger.
- **SC-010**: Ante un fallo de escritura, el usuario recibe un aviso perceptible en **5 segundos** o menos.

*Justificación de los umbrales:* los 50 ms de SC-006 son el techo por debajo del cual la escritura no puede afectar a la aparición de la frase siguiente, dado que el ritmo real es de una cada varios segundos. SC-007 exige que el coste sea constante y no proporcional al tamaño de la reunión — que es exactamente el defecto que 009 identificó en otra parte del sistema. La pérdida de "una frase como mucho" de SC-001 es el límite físico honesto: entre confirmar una frase y terminar de escribirla hay una ventana que ninguna técnica elimina, solo acorta.

## Key Entities

- **Registro de sesión en curso**: el diario de lo que va ocurriendo en la reunión activa. Se escribe entrada a entrada, nunca se reescribe entero, y sobrevive a que la app desaparezca. Se borra solo cuando la sesión queda archivada.
- **Entrada de registro**: una frase confirmada, o el resultado de una traducción. Cada una se escribe una sola vez y es independiente de las demás, de modo que una escritura cortada solo afecta a la última.
- **Sesión recuperable**: lo que se reconstruye al arrancar si el registro no estaba vacío. Debe ser indistinguible de la sesión original a ojos del usuario.
- **Conversación archivada**: lo que ya existe hoy en el historial. No cambia de forma.

## Assumptions

- La feature 008, validada en dispositivo, es la línea base. Se conservan sus decisiones: motor local retirado, esquema persistido sin migrar, histórico de sesión sin recortes.
- **Sin dependencias nuevas.**
- El registro de recuperación es interno, no un fichero que el usuario deba ver o gestionar.
- Una reunión de dos horas produce del orden de cientos de frases, no cientos de miles. El registro es pequeño en términos de almacenamiento.
- La validación de la recuperación se hace en dispositivo físico, matando la app de verdad. El simulador no reproduce la muerte por presión de memoria.
- Esta feature **no** aborda los cinco puntos de la especificación 009, ni la identificación de hablantes, ni el desmenuzado de frases detectado el mismo día. Son problemas reales y están registrados aparte.
