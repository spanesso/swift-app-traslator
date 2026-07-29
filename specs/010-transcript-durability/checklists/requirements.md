# Specification Quality Checklist: Durabilidad del texto de la reunión

**Purpose**: Validate specification completeness and quality before proceeding to planning
**Created**: 2026-07-28
**Feature**: [spec.md](../spec.md)

## Content Quality

- [x] No implementation details (languages, frameworks, APIs)
- [x] Focused on user value and business needs
- [x] Written for non-technical stakeholders
- [x] All mandatory sections completed

## Requirement Completeness

- [x] No [NEEDS CLARIFICATION] markers remain
- [x] Requirements are testable and unambiguous
- [x] Success criteria are measurable
- [x] Success criteria are technology-agnostic (no implementation details)
- [x] All acceptance scenarios are defined
- [x] Edge cases are identified
- [x] Scope is clearly bounded
- [x] Dependencies and assumptions identified

## Feature Readiness

- [x] All functional requirements have clear acceptance criteria
- [x] User scenarios cover primary flows
- [x] Feature meets measurable outcomes defined in Success Criteria
- [x] No implementation details leak into specification

## Notes

### Por qué esta especificación no tiene preguntas abiertas

A diferencia de las features 008 y 009, aquí no hubo decisiones de alcance que consultar. El requisito lo fijó el usuario sin ambigüedad: *"el texto de la reunión es lo más valioso para esta app, no se puede perder por nada del mundo"*. Todo lo demás se deduce de ahí.

Las tres alternativas que normalmente se preguntarían quedaron resueltas por el propio enunciado:

- **¿Guardado automático o manual?** Automático. Depender de que el usuario recuerde pulsar Guardar, con el botón que destruye al lado, es el fallo de diseño que motivó la feature.
- **¿Recuperar o descartar al arrancar?** Recuperar es la acción por defecto; descartar exige confirmación y está marcado como destructivo.
- **¿Cuánta pérdida es aceptable?** Una frase, la que se esté escribiendo en ese instante. Es el límite físico honesto, no una elección de producto.

### Estado de implementación — 2026-07-28

Implementada y verificada en la misma sesión.

- Compilación limpia, **cero warnings de concurrencia** (puerta G5).
- **52 pruebas unitarias pasan**, 10 de ellas específicas de durabilidad.
- La prueba que sostiene la promesa es `testTruncatedJournalKeepsEveryWholeEntry`: corta el registro a mitad de una entrada y verifica que las 20 anteriores sobreviven intactas.
- `testWriteCostDoesNotGrowWithMeetingLength` verifica SC-007: escribir la frase 500 no cuesta más que la primera.
- `testBeginSessionRefusesToOverwriteAPendingJournal` protege el caso peor: abrir una sesión nueva no puede destruir la reunión que la recuperación aún no ha entregado.

**Sin validar en dispositivo físico**, y esto es lo que falta para poder afirmar que el problema está resuelto:

| Criterio | Cómo probarlo |
|---|---|
| SC-001 | Grabar 5 min, cerrar la app desde el selector, reabrir |
| SC-002 | Grabar con pantalla bloqueada, forzar presión de memoria, reabrir |
| SC-004 | Grabar, detener, **no** pulsar Guardar, abrir el historial |
| SC-006 | Medir el coste de persistir en dispositivo, no en simulador |

El simulador no reproduce la muerte por presión de memoria ni la clase de protección de ficheros con el dispositivo bloqueado — que son justamente los dos escenarios que motivaron la feature.

### Deuda reconocida

El caso de **pantalla nunca desbloqueada desde el arranque del dispositivo** no se puede resolver: el cifrado impide escribir y ninguna técnica lo evita. Está declarado en el spec como límite, no escondido.
