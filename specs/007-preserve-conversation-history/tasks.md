---
description: "Task list for Preserve Full Conversation History"
---

# Tasks: Preserve Full Conversation History

**Input**: Design documents from `/specs/007-preserve-conversation-history/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/, quickstart.md

**Tests**: No automated test tasks are generated. The spec did not request TDD, and the
existing `TranslatorAppUITests` are scaffolding only. Verification is manual per `quickstart.md`.

**Organization**: Tasks are grouped by user story. US1 (retain full history) is the MVP and
delivers the fix on its own; US2 (auto-follow + long-session responsiveness) hardens it.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: US1 / US2 (maps to spec.md user stories)
- All paths are repository-relative from the project root.

## Path Conventions

- Mobile app (iOS), Presentation layer only:
  - `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`
  - `TranslatorApp/Presentation/Views/LiveTranscriptionPanes.swift`
  - `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` (host, expected unchanged)

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Establish a known-good baseline before touching code.

- [X] T001 Confirm baseline builds on an iOS target: `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'generic/platform=iOS' build`, and note current behavior (history truncates at ~50 EN / ~30 ES) so the fix can be compared against it.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: None. This is a focused Presentation-layer bug fix; there is no shared
infrastructure to build before the user stories. Proceed directly to Phase 3.

**Checkpoint**: Baseline confirmed — user story work can begin.

---

## Phase 3: User Story 1 - Read back the entire conversation (Priority: P1) 🎯 MVP

**Goal**: Retain every distinct EN phrase and ES sentence for the full duration of an active
session so scrolling to the top always shows the start of the conversation.

**Independent Test**: Run a session producing > 50 EN phrases / > 30 ES sentences, scroll each
pane to the top, and confirm the first captured phrase/sentence is still present (quickstart T-A).

### Implementation for User Story 1

- [X] T002 [US1] In `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`, remove the EN history cap: delete the `if self.emittedPhrases.count > self.maxEmitted { self.emittedPhrases.removeFirst() }` trim inside the `stableStream` loop (around line 185) so `emittedPhrases` is append-only during a session.
- [X] T003 [US1] In the same file, remove the ES history cap: delete the `if translatedSentences.count > maxTranslated { translatedSentences.removeFirst() }` trim inside `appendTranslation` (around line 214) so `translatedSentences` is append-only during a session.
- [X] T004 [US1] In the same file, remove the now-unused `private let maxEmitted = 50` and `private let maxTranslated = 30` constants (around lines 66–67); confirm no other references remain (grep the file).
- [X] T005 [US1] Verify `startRecording(preservingSession:)` still clears history ONLY when `preservingSession == false` (around lines 147–151) — i.e., a new session resets, an internal restart preserves. No code change expected; confirm behavior matches FR-005/FR-006.
- [X] T006 [US1] Verify Save/Export completeness: confirm `exportText`, `exportDocument`, and `saveConversation()` serialize the full `emittedPhrases`/`translatedSentences` (they already do) so a long session exports end-to-end (FR-007). No code change expected.
- [X] T007 [US1] Build and run quickstart tests T-A (full history), T-C (restart continuity), T-D (new-session reset), and T-E (export completeness). Fix any regression before proceeding.

**Checkpoint**: User Story 1 delivers the fix — the entire conversation is retained and scrollable.

---

## Phase 4: User Story 2 - Auto-follow without hiding history + long-session responsiveness (Priority: P2)

**Goal**: Keep live auto-follow intact and keep the UI responsive as history grows unbounded.

**Independent Test**: During a 20–30 min session, auto-follow still tracks the newest line;
scrolling from newest to the first phrase stays smooth (quickstart T-B and T-F).

### Implementation for User Story 2

- [X] T008 [P] [US2] In `TranslatorApp/Presentation/Views/LiveTranscriptionPanes.swift`, change the EN pane's growing list container from `VStack` to `LazyVStack` inside `englishPane()`'s `ScrollView` (keep the `ForEach(... id: \.offset)`, the `raw_end` anchor, and the `.onChange` auto-scroll intact).
- [X] T009 [P] [US2] In the same file, change the ES pane's growing list container from `VStack` to `LazyVStack` inside `spanishPane()`'s `ScrollView` (keep the `tr_bottom` anchor, `.defaultScrollAnchor(.bottom)`, and `.onChange` auto-scroll intact).
- [X] T010 [US2] In `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`, remove the per-partial `emittedPhrases.joined(separator: " ")` cost in the `rawStream` loop (around line 165): cache the committed-prefix string (and its word count) and recompute it only when `emittedPhrases` changes (on commit in the `stableStream` loop), so per-partial handling is O(1) in history length. Preserve the existing prefix-stripping semantics for `currentBuffer` exactly.
- [X] T011 [US2] Build and run quickstart tests T-B (auto-follow not regressed) and T-F (long-session responsiveness). Confirm no stutter and that scrolling up does not interrupt live updates.

**Checkpoint**: US1 + US2 both hold — full retention with smooth, uninterrupted live behavior.

---

## Phase 5: Polish & Cross-Cutting Concerns

**Purpose**: Regression sweep and documentation.

- [X] T012 Run the full quickstart regression checklist: duplicate suppression, confidence styling, translation model download/unavailable banners, and Save/Export all still work.
- [X] T013 Build with strict concurrency and confirm no new Swift warnings introduced by the change: `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'generic/platform=iOS' build`.
- [X] T014 [P] Update `CLAUDE.md` "Full-array dedup in ViewModel" / Presentation notes to state that in-session history is unbounded (no `maxEmitted`/`maxTranslated` caps) and cleared only on a new (non-continuing) session.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately.
- **Foundational (Phase 2)**: Empty — no blocking work.
- **User Story 1 (Phase 3)**: The MVP. Delivers the fix independently.
- **User Story 2 (Phase 4)**: Builds on US1 (retention must exist first for the perf/rendering
  hardening to matter). T010 depends on T002 being in place (same loop context).
- **Polish (Phase 5)**: After US1 (and US2 if included).

### Within/Across Stories

- T002, T003, T004 touch the same file (`TranscriptionViewModel.swift`) → sequential, NOT [P].
- T005, T006 are verification-only (no edit) and can be done alongside T002–T004.
- T008 and T009 edit the same file (`LiveTranscriptionPanes.swift`) but different functions;
  marked [P] for planning but apply as one edit pass to avoid conflicts.
- T010 edits `TranscriptionViewModel.swift` again → do after Phase 3 edits land.

### Parallel Opportunities

- T008 / T009 (both panes) are conceptually parallel — apply together in one edit session.
- T014 (docs) is [P] with the final build check.

---

## Implementation Strategy

### MVP First (User Story 1 only)

1. T001 baseline build.
2. Phase 3 (T002–T007): remove the caps and verify retention/restart/export.
3. **STOP and VALIDATE** with quickstart T-A/T-C/T-D/T-E. This alone resolves the reported bug.

### Incremental Delivery

1. Ship US1 as the fix (MVP).
2. Add US2 (LazyVStack + committed-prefix cache) to guarantee smoothness on long sessions.
3. Polish: regression sweep + docs.

---

## Notes

- The whole change is Presentation-only; Domain and Data layers are untouched (Clean Architecture rule).
- Do not reintroduce any count-based `removeFirst()` on the history arrays — that is the root-cause bug.
- No new dependencies; build must stay warning-free under strict concurrency.
- Commit after Phase 3 (MVP) and after Phase 4, per the repo's manual-git workflow (ask the user).
