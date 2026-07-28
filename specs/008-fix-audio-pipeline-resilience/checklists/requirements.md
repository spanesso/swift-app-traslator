# Specification Quality Checklist: Resiliencia del pipeline de audio en vivo

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

### Iteración de validación 1 — 2026-07-28

**Correcciones aplicadas durante la redacción:**

- Se eliminaron los nombres de clase, archivo y framework del cuerpo del spec. El detalle anclado a archivo y línea vive en `DIAGNOSIS_AUDIO_PIPELINE.md`, que es el insumo de la fase de planificación, no el spec.
- Los criterios de éxito se reescribieron en términos observables por el usuario (huecos en ms, palabras omitidas, frases emitidas, fragmentos con ambos idiomas) en vez de en términos de estado interno.
- Cada umbral numérico lleva su justificación explícita en el propio spec, para que no se renegocie por costumbre durante la implementación.
- Las siete historias se ordenaron de modo que cada una sea desplegable por separado. US1 (observabilidad) va primera porque sin ella ninguna de las otras seis puede demostrarse cerrada en campo.

### Iteración de validación 2 — 2026-07-28

Los tres marcadores `[NEEDS CLARIFICATION]` quedaron resueltos por decisión directa del usuario y se sustituyeron por requisitos firmes. Ver la sección **Decisiones de alcance resueltas** del spec.

| # | Elección | Impacto en el spec |
|---|---|---|
| Q1 | Retirar el motor de reconocimiento local en esta fase | US4 reescrita (de "que funcione" a "que no se seleccione"). FR-017…FR-022 reescritos. Eliminados los criterios de carga por ventana; añadido SC-019 |
| Q2 | Conservar dos bloques de texto, añadir marcadores | US7 reescrita con correspondencia **posicional por línea**. FR-037…FR-044 reescritos. Entidad "Fragmento de conversación" pasa a existir solo en memoria. SC-020…SC-025 reescritos |
| Q3 | Capturar con pantalla bloqueada **y** recuperar interrupciones desatendidas | **US5 elevada de P2 a P1.** Nuevo estado *suspendido* de la sesión de grabación. FR-023…FR-033 reescritos. Añadidos SC-006, SC-007 y SC-011 |

**Aportación del usuario que no estaba en las opciones ofrecidas:** una alarma o una llamada que el usuario **nunca atiende** hoy mata la escucha igual que un stop deliberado. Se convirtió en el eje de US5 (escenarios 1–5), en FR-023/FR-024 y en SC-006/SC-007. Es la diferencia entre "terminar la sesión" y "suspenderla", y era el hueco real del borrador inicial.

**Advertencia registrada y aceptada:** la opción elegida en Q3 converge en la práctica con habilitar el modo de audio en segundo plano en iOS, con su impacto en batería y en la revisión de la tienda. Se advirtió antes de decidir; el usuario optó por seguir. Queda anotado en Assumptions para que la planificación lo dimensione y no aparezca como sorpresa.

**Estado:** los 16 ítems del checklist pasan. El spec está listo para `/speckit.plan`.
