# Phase 0 Research: Preserve Full Conversation History

No open `NEEDS CLARIFICATION` items remained after `/speckit.specify`. This document records
the root-cause investigation and the design decisions that resolve the reported defect while
protecting existing behavior.

## R1. Root cause of the disappearing history

**Decision**: The loss is caused by destructive in-session trimming in `TranscriptionViewModel`,
not by the ASR/segmenter failing to capture speech.

**Evidence** (`TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`):
- `private let maxTranslated = 30` and `private let maxEmitted = 50` (lines 66–67).
- EN pane trim on commit: `if self.emittedPhrases.count > self.maxEmitted { self.emittedPhrases.removeFirst() }` (line 185).
- ES pane trim on commit: `if translatedSentences.count > maxTranslated { translatedSentences.removeFirst() }` (line 214).

Once 50 EN phrases / 30 ES sentences accumulate, each new commit deletes the oldest entry.
Scrolling up therefore reveals only the most recent ~50/~30 items — exactly the symptom
("subo con el scroll y solo encuentro poco texto").

**Rationale**: `removeFirst()` on a growing array, gated by a small constant, is a classic
bounded-buffer that silently discards the head. It was almost certainly added as a naive
memory/perf guard, but the guard is far too aggressive for a tool whose value is reviewing the
whole conversation.

**Alternatives considered**:
- *Keep a larger cap (e.g., 500)*: Rejected — still silently loses content on genuinely long
  sessions and reintroduces the same class of bug at a higher threshold. Violates FR-003.
- *Move history to on-disk storage during capture*: Rejected — unnecessary. Text volume is
  tiny; in-memory retention for one session is sufficient and matches existing architecture.

## R2. Memory cost of unbounded in-session history

**Decision**: Retain the full session in memory; do not cap.

**Rationale**: Spoken conversation produces little text. Even an extreme 3-hour session at a
fast speaking rate yields on the order of a few thousand short phrases; at ~100–200 bytes per
`String`/`TranslationEntry`, total footprint is well under a few MB. Memory is not the binding
constraint — render/update CPU cost is (see R3, R4).

**Alternatives considered**: On-disk paging / windowed virtualization of history — rejected as
premature optimization for the realistic data volume.

## R3. Rendering a growing list without jank (FR-009, SC-005)

**Decision**: Render the growing history with `LazyVStack` inside the existing `ScrollView`
for both panes, keeping the append-only `id` scheme stable.

**Rationale**: The current panes use `ScrollView { VStack { ForEach(...) } }`. A plain `VStack`
materializes every child eagerly; with the cap removed this means building hundreds/thousands
of `Text` views on every update. `LazyVStack` renders only on-screen rows, keeping scroll and
live updates smooth for long sessions. `ScrollViewReader` + the `raw_end`/`tr_bottom` anchors
and `.scrollTo` auto-follow continue to work with `LazyVStack`.

**ID stability note**: `ForEach(Array(emittedPhrases.enumerated()), id: \.offset)` uses the
array offset as identity. This was *unstable* under `removeFirst()` (every element's offset
shifted on each trim, forcing full diffs). With trimming removed the history is strictly
append-only, so offsets are stable and existing rows are never re-identified — the offset `id`
becomes safe. We keep it to minimize churn (no data-model change required).

**Alternatives considered**:
- *List instead of ScrollView+LazyVStack*: Rejected — would change styling/insets and risk
  regressing the custom pane appearance and auto-scroll anchors.
- *Switch IDs to a stable per-phrase identifier*: Deferred — not required now that append-only
  makes offsets stable; would be a larger change. Revisit only if a future feature can mutate
  history in the middle.

## R4. Hot-path cost of committed-prefix computation

**Decision**: Avoid recomputing `emittedPhrases.joined(separator: " ")` on every raw ASR
partial when the joined string is only needed to strip the committed prefix from the live buffer.

**Evidence**: In the raw-stream loop, `let committed = self.emittedPhrases.joined(separator: " ")`
(line 165) runs for every partial ASR update (many per second). With an unbounded history this
becomes an O(n) allocation per partial and grows with session length — a real regression risk
introduced by removing the cap.

**Rationale**: Cache the joined committed string and its word count, invalidating/recomputing
only when `emittedPhrases` actually changes (i.e., on commit), not on every raw partial. This
keeps per-partial work O(1) in history length and protects SC-004 (auto-follow latency) and
SC-005 (responsiveness) for long sessions.

**Alternatives considered**:
- *Leave the join as-is*: Rejected — reintroduces a length-dependent cost the cap previously
  masked; would degrade long sessions, contradicting the fix's intent.
- *Only compare against the last committed phrase*: Rejected — changes the prefix-stripping
  semantics and could reintroduce duplicated words in the live buffer.

## R5. Continuity across listener restart (FR-005)

**Decision**: No change needed — verify only.

**Rationale**: `restartListening()` calls `startRecording(preservingSession: true)`, and
`startRecording` clears history only when `!preservingSession`. So an internal restart already
preserves `emittedPhrases`, `translatedSentences`, and `emittedPhraseSet`. The plan adds a
verification step rather than code.

## R6. Save / Export completeness (FR-007)

**Decision**: No change needed — the fix cascades.

**Rationale**: `exportText`, `exportDocument`, and `saveConversation()` already serialize the
full `emittedPhrases` / `translatedSentences` arrays. Once trimming is removed, saved and
exported transcripts automatically contain the complete session. Add a verification step.

## Summary of decisions

| Area | Decision |
|------|----------|
| Root cause | Destructive `removeFirst()` trimming under `maxEmitted`/`maxTranslated` |
| Fix | Remove both caps; retain full session in memory |
| Rendering | `LazyVStack` in both panes; keep append-only offset IDs (now stable) |
| Hot path | Cache committed-prefix join; recompute only on commit |
| Restart continuity | Already correct — verify |
| Save/Export | Already complete once caps removed — verify |
