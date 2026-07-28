# UI/State Contract: Session History

This app exposes no network API. Its relevant "contract" is the observable state that
`TranscriptionViewModel` (`@Observable`, `@MainActor`) presents to the live SwiftUI panes.
This document pins the behavior the panes may rely on after the fix.

## Provider: `TranscriptionViewModel`

### Published history state

| Member | Type | Guarantee (post-fix) |
|--------|------|----------------------|
| `emittedPhrases` | `[String]` | Append-only during a session; chronological; **never trimmed** while recording. Index 0 = first phrase of the session. |
| `translatedSentences` | `[TranslationEntry]` | Append-only during a session; chronological; **never trimmed** while recording. Deduplicated on insert. |
| `currentBuffer` | `String` | Live uncommitted EN tail; unchanged semantics. |
| `latestSegmentConfidence` | `Float` | Unchanged; drives live buffer opacity. |

### Behavioral contract

1. **No destructive trimming (FR-003/FR-004)**: While `isRecording == true`, neither history
   array shrinks. The only removals allowed are on an explicit **new** session start.
2. **New session reset (FR-006)**: `startRecording(preservingSession: false)` clears both
   arrays and `emittedPhraseSet`. This is the ONLY history-clearing path a user can trigger.
3. **Restart preserves (FR-005)**: `startRecording(preservingSession: true)` (invoked by
   `restartListening()`) leaves both arrays intact.
4. **Duplicate suppression preserved**: `appendTranslation` still rejects equal/contained/
   containing sentences; `emittedPhraseSet` still prevents duplicate EN phrases.
5. **Export/save completeness (FR-007)**: `exportText`, `exportDocument`, and
   `saveConversation()` reflect the full history, unbounded.
6. **Hot-path neutrality (SC-004/SC-005)**: Per-partial raw-stream handling is O(1) in history
   length (committed-prefix cache); auto-follow latency is unchanged versus current behavior.

## Consumer: `LiveTranscriptionPanes` (`englishPane` / `spanishPane`)

### Contract the panes must honor

1. **Read-only**: Panes render history; they never mutate it.
2. **Lazy rendering**: Growing history is rendered with `LazyVStack` (not eager `VStack`) so
   off-screen rows are not materialized (FR-009/SC-005).
3. **Stable identity**: `ForEach` identity (`\.offset`) is valid because history is append-only;
   existing rows keep their identity across updates. If history ever becomes mid-mutable in a
   future feature, identity must move to a stable per-item key.
4. **Auto-follow preserved (FR-008)**: `ScrollViewReader` + `raw_end` / `tr_bottom` anchors and
   `.scrollTo(..., anchor: .bottom)` continue to follow the newest item on append; scrolling up
   to inspect history is not interrupted by trimming (there is none).

## Acceptance mapping

| Requirement | Enforced by |
|-------------|-------------|
| FR-001, FR-002 | Append-only arrays, no trimming |
| FR-003, FR-004 | Contract items 1–3 |
| FR-005 | `preservingSession: true` path |
| FR-006 | `preservingSession: false` reset |
| FR-007 | Export/save read full arrays |
| FR-008 | Auto-follow anchors retained |
| FR-009 | LazyVStack + committed-prefix cache |
