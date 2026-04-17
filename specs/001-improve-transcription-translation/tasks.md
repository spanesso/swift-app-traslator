# Tasks: Improve Live Transcription & Translation Quality

**Input**: Design documents from `specs/001-improve-transcription-translation/`
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/ ✓, quickstart.md ✓

**Tests**: Not requested — manual test cases are defined in quickstart.md (TC-1 through TC-5).

**Organization**: Tasks grouped by user story. Each story is independently deliverable.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

---

## Phase 1: Setup

**Purpose**: Verify baseline before any changes.

- [x] T001 Verify project compiles clean by running `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' build` and confirming zero errors

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Core infrastructure shared by multiple user stories. MUST complete before US1 and US3.

**⚠️ CRITICAL**: US1 depends on T002 (committedFullText protocol addition). US3 depends on T003 (TranslationContextWindow).

- [x] T002 Update `NLPSegmenterServiceProtocol` to expose `var committedFullText: String { get }` in `TranslatorApp/Domain/Interfaces/NLPSegmenterServiceProtocol.swift`
- [x] T003 [P] Create `TranslationContextWindow.swift` in `TranslatorApp/Domain/Services/TranslationContextWindow.swift` as a `struct` with `windowSize: Int = 3`, a ring-buffer of `(original: String, translated: String)` pairs, `mutating func append(original:translated:)`, `func contextString() -> String` returning `"Previously: \"<s1>\" → \"<t1>\"."` format, and `func requestText(for:) -> String` returning `"[Context: <ctx>]\n\n<sentence>"` when context exists or just `<sentence>` when empty

**Checkpoint**: Protocol updated and TranslationContextWindow compiles — US1 and US3 work can begin.

---

## Phase 3: User Story 1 — Clean Streaming Transcription Display (Priority: P1) 🎯 MVP

**Goal**: The original-language column never shows duplicate lines or repeated content. `currentBuffer` shows only uncommitted tail text, not the full accumulated transcript.

**Independent Test**: Speak continuously for 2 minutes. The original column must never show any phrase more than once. The green live-text area must show only words not yet moved to committed (gray) phrases.

### Implementation for User Story 1

- [x] T004 [US1] Fix `pendingSuffix(of:)` in `TranslatorApp/Domain/Services/NLPSegmenterService.swift` to use string-prefix stripping instead of word-count diffing: strip `committedFullText` (trimmed) as a prefix from `fullText` (trimmed), returning the remainder — making differential emit immune to ASR correction word-count drift
- [x] T005 [US1] Satisfy the `committedFullText` protocol requirement added in T002 by exposing `NLPSegmenterService.committedFullText` as an internal property (it already exists as `private` — change visibility to `internal`) in `TranslatorApp/Domain/Services/NLPSegmenterService.swift`
- [x] T006 [P] [US1] Add `private var emittedPhraseSet: Set<String> = []` to `TranscriptionViewModel` in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` and update the `emittedPhrases.append(sentence)` call to guard against duplicates: `guard emittedPhraseSet.insert(sentence).inserted else { return }` before appending
- [x] T007 [US1] Update the raw-stream consumer `Task` in `TranscriptionViewModel.startRecording()` in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` so that `currentBuffer` is set to the uncommitted tail only: after receiving each raw `segment`, compute `tail = segment.text.stripPrefix(transcribeUseCase.segmenter.committedFullText)` (normalized) and assign `self.currentBuffer = tail` instead of `self.currentBuffer = segment.text`

**Checkpoint**: At this point, the original-language column shows no duplicates and the live green text does not repeat committed phrases. Verify with quickstart.md TC-5 (5-minute session).

---

## Phase 4: User Story 2 — Semantic Sentence Segmentation (Priority: P2)

**Goal**: No sentence is split across two translation requests. Translation units are triggered by punctuation, sustained silence, or a maximum phrase length — whichever comes first.

**Independent Test**: Speak 10 sentences with natural punctuation. Each sentence must appear as exactly one `emittedPhrase` (no sentence split across two entries). Speak one sentence > 20 words without pausing — it must flush at a clause boundary, not mid-word.

### Implementation for User Story 2

- [x] T008 [US2] Add `var maxFlushDelay: TimeInterval = 5.0` parameter to `NLPSegmenterService` in `TranslatorApp/Domain/Services/NLPSegmenterService.swift` — this controls how long to hold a partial buffer after the user stops speaking (used when the stability timer fires but content is below `minShortPhraseWords`, or when the session ends)
- [x] T009 [US2] Implement stop-recording flush in `NLPSegmenterService.processStream()` in `TranslatorApp/Domain/Services/NLPSegmenterService.swift`: in the "stream end flush" path (after the `for await` loop), emit any remaining `pendingSuffix` content unconditionally (bypassing the `minShortPhraseWords` guard) so buffered content is never lost when recording stops
- [x] T010 [US2] Audit and add a debug-level `OSLog` `Logger` call (category `"Segmenter"`) in `TranslatorApp/Domain/Services/NLPSegmenterService.swift` after each emit path (sentence / terminator / final / clause / stability / flush) logging `tag`, `emitted text`, and `word count` — enables manual verification of TC-2 from quickstart.md

**Checkpoint**: Speak TC-1 from quickstart.md ("In a nutshell, we restructured the team."). `emittedPhrases` must contain exactly one entry for that sentence, and OSLog must show tag `"terminator"` or `"sentence"` (not `"clause"` or `"stability"` splitting it in two).

---

## Phase 5: User Story 3 — Context-Aware Translation (Priority: P3)

**Goal**: Each translation request includes the last N (original, translated) sentence pairs as a context block, enabling the engine to resolve idioms, pronouns, and references correctly.

**Independent Test**: Speak TC-3 from quickstart.md (pronoun reference across sentences). "It was excellent." must translate with correct pronoun resolution. Speak TC-1 — "in a nutshell" must render as "en pocas palabras".

### Implementation for User Story 3

- [x] T011 [P] [US3] Add `private var translationContext = TranslationContextWindow()` property to `TranscriptionViewModel` in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` (depends on T003)
- [x] T012 [US3] Update `appendTranslation` signature in `TranscriptionViewModel` to `func appendTranslation(_ translation: String, originalSentence: String)` in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`, and add `translationContext.append(original: originalSentence, translated: trimmed)` after appending to `translatedSentences`
- [x] T013 [US3] Update the `.translationTask` modifier in `LiveTranscriptionView` in `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift`: before calling `session.translate(_:)`, extract the actual sentence from the request (last component after `"\n\n"` split), and update the `viewModel.appendTranslation` call to pass `originalSentence: sentence`
- [x] T014 [US3] Update the translation request yield in `TranscriptionViewModel.startRecording()` in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` to yield `translationContext.requestText(for: sentence)` instead of `sentence` directly — this injects the context block into each translation request
- [x] T015 [US3] Add a response-stripping guard in the `.translationTask` modifier in `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift`: after `session.translate(_:)` returns, strip any `[Context: ...]` prefix leaked into `response.targetText` using a regex `#"^\[Context:[^\]]*\]\n\n?"#` before calling `appendTranslation`

**Checkpoint**: Speak TC-1 and TC-3 from quickstart.md. Translation column must show contextually correct idiom translation and pronoun resolution without any `[Context: ...]` text leaking into the displayed output.

---

## Phase 6: User Story 4 — Stable Translation Column (Priority: P4)

**Goal**: The translation column only shows finalized, complete translations. Once a translation line is displayed, it is never modified, removed, or flickered. Duplicate translations are fully eliminated.

**Independent Test**: Observe the translation column for 5 minutes. No previously displayed translation line must ever change. Speak the same sentence twice — it must appear only once.

### Implementation for User Story 4

- [x] T016 [US4] Replace the last-item-only dedup guard in `appendTranslation` in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` with a full-array scan: `guard !translatedSentences.contains(where: { $0 == trimmed || trimmed.contains($0) || $0.contains(trimmed) }) else { return }` — catches exact duplicates, subset containment, and superset containment across the full session history
- [x] T017 [US4] Add a whitespace/empty guard at the top of `appendTranslation` in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`: `let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines); guard !trimmed.isEmpty, trimmed.split(separator: " ").count >= 1 else { return }` — prevents empty or whitespace-only strings from appending to the translation column

**Checkpoint**: Run TC-5 (5-minute session) from quickstart.md. Translation column must grow monotonically. Speak one sentence twice; only one translation must appear.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Wire configurable parameters, validate compilation, and confirm manual test cases pass.

- [x] T018 [P] Update `DependencyContainer.swift` in `TranslatorApp/App/DependencyContainer.swift` to configure `NLPSegmenterService` with explicit parameter values: `stabilityDelay: 700_000_000` (ns), `longSentenceWordThreshold: 15`, `maxFlushDelay: 5.0`, and `TranslationContextWindow` with `windowSize: 3` — documenting defaults as a reference comment
- [x] T019 [P] Expose `segmenter` (or its `committedFullText`) from `TranscribeAudioUseCase` so `TranscriptionViewModel` can access it for the tail computation in T007 — add `var segmenter: NLPSegmenterServiceProtocol { get }` property to `TranscribeAudioUseCase` in `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift` if not already accessible
- [x] T020 Run `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' build` and resolve any compilation errors introduced by signature changes (especially `appendTranslation` parameter addition in T012)
- [x] T021 Manually execute all 5 test cases from `specs/001-improve-transcription-translation/quickstart.md` (TC-1 through TC-5) and confirm expected behaviors

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 — BLOCKS US1 (T004–T007) and US3 (T011–T015)
- **US1 (Phase 3)**: Depends on T002 (protocol) — can start once T002 done (T003 runs in parallel)
- **US2 (Phase 4)**: Depends on Phase 3 (pendingSuffix fix in T004 enables correct behavior) — or can run concurrently if T004 is done
- **US3 (Phase 5)**: Depends on T003 (TranslationContextWindow) — can start once T003 done
- **US4 (Phase 6)**: Independent of US1–US3 — can start after Foundational phase
- **Polish (Phase 7)**: Depends on all user story phases completing

### User Story Dependencies

- **US1 (P1)**: Requires T002 from Foundational
- **US2 (P2)**: Independent; best done after US1 since both touch `NLPSegmenterService`
- **US3 (P3)**: Requires T003 from Foundational; requires T012 (appendTranslation signature) from US3 before US4
- **US4 (P4)**: Independent; touches only `TranscriptionViewModel.appendTranslation`

### Within Each User Story

- T004 → T005 → T007 (sequential: fix algorithm, expose property, consume it)
- T006 can run in parallel with T004/T005 (different property, same file but no conflict)
- T011 → T012 → T014 (sequential: add property, update signature, use it in yield)
- T013, T015 touch `LiveTranscriptionView.swift` — do sequentially

### Parallel Opportunities

- T003 and T002 can run in parallel (different files)
- T006 and T004/T005 can run in parallel within US1 (non-conflicting changes)
- T011 and T016/T017 can run in parallel (T011 adds property; T016/T017 update appendTranslation method body)
- T018 and T019 can run in parallel in Polish phase
- US3 and US4 can proceed concurrently after Foundational completes

---

## Parallel Example: Foundational Phase

```
Parallel launch:
  Task T002: Update NLPSegmenterServiceProtocol (1 file)
  Task T003: Create TranslationContextWindow.swift (new file)
```

## Parallel Example: User Story 1

```
Sequential:
  T004 → T005 → T007  (algorithm fix → expose → consume)

Parallel with above:
  T006  (emittedPhraseSet dedup — independent property addition)
```

---

## Implementation Strategy

### MVP First (User Story 1 Only)

1. Complete Phase 1: Setup (T001)
2. Complete Phase 2: Foundational (T002, T003)
3. Complete Phase 3: User Story 1 (T004–T007)
4. **STOP and VALIDATE**: Speak for 2 minutes, confirm zero duplicates in original column
5. Ship US1 fix if validated

### Incremental Delivery

1. Setup + Foundational → baseline ready
2. US1 (T004–T007) → no more visual duplication (highest user impact)
3. US2 (T008–T010) → no more mid-sentence cuts (translation coherence improves)
4. US3 (T011–T015) → context-aware idiom/pronoun translation
5. US4 (T016–T017) → fully stable translation column
6. Polish (T018–T021) → wired parameters, compile-verified, all TCs passing

---

## Notes

- [P] tasks operate on different files or non-conflicting sections — safe to parallelize
- No new external dependencies introduced in any task
- `appendTranslation` signature change (T012) will require updating its call site in `LiveTranscriptionView.swift` (T013) — do these in the same session
- The `committedFullText` exposure (T005) changes `private` → `internal` visibility — this is the minimal change; do not make it `public`
- All configurable parameters in T018 should be documented with a `// default: X` comment as the only in-code documentation
- Total tasks: **21** (T001–T021)
