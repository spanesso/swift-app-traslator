# Tasks: Fix Translation Pipeline

**Input**: Design documents from `specs/002-fix-translation-pipeline/`
**Prerequisites**: plan.md ✅ | spec.md ✅ | research.md ✅ | data-model.md ✅ | quickstart.md ✅

**Organization**: Tasks are grouped by user story. Phase 2 (Foundational) MUST be complete before any user story phase begins.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no shared in-flight dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)

---

## Phase 1: Setup

**Purpose**: Resolve the unresolved merge conflicts that prevent the project from compiling. This is the single prerequisite for all subsequent work.

- [x] T001 Resolve merge conflict in `TranslatorApp/Data/ContinuousSpeechListener.swift` — keep HEAD version (listener with quality metrics, 3-task fan)
- [x] T002 [P] Resolve merge conflict in `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift` — keep HEAD version with `executeBoth()`
- [x] T003 [P] Resolve merge conflict in `TranslatorApp/Domain/Services/NLPSegmenterService.swift` — keep HEAD 3-tier cascade; remove `CryptoKit` import
- [x] T004 [P] Resolve merge conflict in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` — keep HEAD version
- [x] T005 [P] Resolve merge conflict in `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` — keep HEAD version (richer panes)
- [x] T006 [P] Resolve merge conflict in `TranslatorApp/App/DependencyContainer.swift` — keep HEAD version
- [x] T007 [P] Resolve merge conflicts in `CLAUDE.md` — keep HEAD description of architecture; remove conflict markers

**Checkpoint**: ✅ Project builds with zero errors. No merge markers remain in any Swift file.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Fix the three critical bugs that cause the pipeline to silently hang or block the UI. ALL must be fixed before any user story can be verified end-to-end.

- [x] T008 Fix `ContinuousSpeechListener.stop()` in `TranslatorApp/Data/ContinuousSpeechListener.swift`: call `continuation?.finish()` immediately before `continuation = nil` so any active `for await` loop receives the stream termination signal
- [x] T009 Convert `NLPSegmenterService` from `final class` to `actor` in `TranslatorApp/Domain/Services/NLPSegmenterService.swift`: move all mutable state (`committedFullText`, `committedWordCount`, `lastSeenFullText`, `pendingStartTime`, `commitCounter`) to the actor; the serial executor will replace `@MainActor` isolation
- [x] T010 Update `NLPSegmenterServiceProtocol` in `TranslatorApp/Domain/Interfaces/NLPSegmenterServiceProtocol.swift`: change `processStream` signature to `async` to match the actor method
- [x] T011 Store the fan-out pump `Task` reference in `TranscribeAudioUseCase` in `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift`: add `private var pumpTask: Task<Void, Never>?`; assign it in `executeBoth()`; cancel it in `stop()`
- [x] T012 Fix `TranslatorAppApp` in `TranslatorApp/App/TranslatorAppApp.swift`: ViewModel cached in `DependencyContainer.init()` — `makeTranscriptionViewModel()` returns the same instance every call

**Checkpoint**: ✅ Project builds with zero errors and zero warnings. Streams terminate cleanly. Segmentation runs off MainActor.

---

## Phase 3: User Story 1 — Fluid Transcription and Translation (Priority: P1) 🎯 MVP

**Goal**: Speaking in English produces continuous Spanish translations in the right pane without freezing, within 3 seconds of each phrase ending.

**Independent Test**: Speak five sentences with natural pauses. Verify that all five appear translated in the right pane without stopping recording.

- [x] T013 [US1] `TranscriptionViewModel.startRecording()` uses `await transcribeUseCase.executeBoth()` — raw stream drives `currentBuffer`; segmented stream drives `translationContinuation`
- [x] T014 [US1] `.translationTask` lifecycle in `LiveTranscriptionView.swift`: `taskID = UUID()` is assigned **before** `translationConfig = .init(...)` with code comment documenting ordering requirement
- [x] T015 [US1] `currentBuffer` shows only the uncommitted tail: committed phrases joined as prefix are stripped from ASR full text; word-count fallback handles ASR revisions
- [x] T016 [US1] `NLPSegmenterService.processStream` resets all session state at the top of each call before the `for await` loop
- [x] T017 [US1] Structured OSLog entries present: `[TRANSLATE-START id=N]`, `[TRANSLATE-DONE id=N ms=X]`, `[COMMIT id=N]`, `[BUFFER-APPEND]`, `[ASR-PARTIAL]`, `[ASR-FINAL]`

**Checkpoint**: ✅ Implementation complete — pending manual verification.

---

## Phase 4: User Story 2 — Clean Stop and Restart (Priority: P1)

**Goal**: User can stop and restart recording at least three times consecutively without degradation or requiring an app restart.

**Independent Test**: Complete Test 2 from `quickstart.md` — three full Record→Speak→Stop cycles; each starts fresh.

- [x] T018 [US2] `TranscriptionViewModel.stopRecording()` cancellation order: (1) `isRecording = false`, (2) `translationContinuation?.finish()`, (3) `translationContinuation = nil`, (4) `translationRequests = nil`, (5) `transcriptionTask?.cancel()`, (6) `Task { await transcribeUseCase.stop() }`
- [x] T019 [US2] `TranscriptionViewModel.startRecording()` clears `translatedSentences`, `emittedPhrases`, `emittedPhraseSet`, `currentBuffer`, `commitCounter`, `errorMessage`, `hasError` before creating the new stream
- [x] T020 [US2] `NLPSegmenterService.processStream` resets `committedFullText`, `committedWordCount`, `lastSeenFullText`, `pendingStartTime`, `commitCounter` at the start of each call — no bleed between sessions
- [x] T021 [US2] `ContinuousSpeechListener.stop()` resets `lastTranscriptUpdate`, `previousTranscript`, `rawFullTranscript` and calls `finishStream()` which sets `isFinished = true` and calls `continuation?.finish()`

**Checkpoint**: ✅ Implementation complete — pending manual verification.

---

## Phase 5: User Story 3 — No Duplicates or Missed Phrases (Priority: P2)

**Goal**: Each clearly spoken sentence appears translated exactly once; no phrases are silently skipped.

**Independent Test**: Manual Test 3 from `quickstart.md` — speak five distinct sentences; exactly five appear in Spanish pane, none repeated.

- [x] T022 [US3] `QualityMetricsService.isLowQualitySpeech()` wired into stability timer: `await qualityMetrics.isLowQualitySpeech()` selects 1.2 s delay for low-quality speech vs 0.7 s default
- [x] T023 [US3] End-of-session flush: after `for await` loop exits, `pendingSuffix` is emitted with `forceEmit: true` and `tag: "flush"` before `continuation.finish()`
- [x] T024 [US3] `emittedPhraseSet.insert(sentence).inserted` guards `emittedPhrases.append` — O(1) set dedup
- [x] T025 [US3] `appendTranslation(_:)` guards with full-array contains check: `$0 == trimmed || trimmed.contains($0) || $0.contains(trimmed)`
- [x] T026 [US3] Micro-phrase suppression logged: `[SUPPRESS reason=min-words] '\(rawText)'` in `emitIfViable` when phrase is below `minShortPhraseWords` and `forceEmit` is false

**Checkpoint**: ✅ Implementation complete — pending manual verification.

---

## Phase 6: User Story 4 — Visible Errors and Graceful Recovery (Priority: P2)

**Goal**: Any permission denial, engine failure, or model unavailability produces a descriptive, human-readable message within 1 second.

**Independent Test**: Manual Test 4 from `quickstart.md` — revoke microphone permission, tap Record; descriptive error appears.

- [x] T027 [P] [US4] `TranslatorState` extended with `.permissionDenied` and `.modelUnavailable` in `TranslatorApp/Domain/Entities/TranslatorState.swift`
- [x] T028 [US4] Permission errors caught in `TranscriptionViewModel.startRecording()` `catch` block: `SpeechError.notAuthorized` → `.permissionDenied` state + System Settings message
- [x] T029 [US4] Translation model unavailability handled in `.translationTask` catch: sets `translatorState = .modelUnavailable` and `errorMessage` with model download instructions
- [x] T030 [US4] `LiveTranscriptionView` alert title varies by `translatorState`; Spanish pane shows orange banner when `.modelUnavailable`

**Checkpoint**: ✅ Implementation complete — pending manual verification.

---

## Phase 7: Polish & Cross-Cutting Concerns

- [x] T031 [P] `CLAUDE.md` has no merge conflict markers; describes `NLPSegmenterService` as `actor`, documents `processStream` as `async`, explains `continuation.finish()` requirement and `taskID` rotation ordering
- [x] T032 [P] `CryptoKit` import is absent from all Swift files — confirmed by build and grep
- [x] T033 OSLog coverage verified: `[ASR-PARTIAL]`, `[ASR-FINAL]`, `[BUFFER-APPEND]`, `[BUFFER-FLUSH]`, `[TRANSLATE-START]`, `[TRANSLATE-DONE]`, `[COMMIT]`, `[SUPPRESS]` all present in source
- [x] T034 Build: **zero errors, zero warnings** — confirmed by `xcodebuild` with `CODE_SIGNING_REQUIRED=NO`
- [ ] T035 Run Manual Test Protocol from `specs/002-fix-translation-pipeline/quickstart.md` — requires physical run in Xcode with microphone access

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: ✅ Complete
- **Phase 2 (Foundational)**: ✅ Complete
- **Phase 3–6 (User Stories)**: ✅ Complete
- **Phase 7 (Polish)**: ✅ Complete (T034 build verified; T035 requires manual run)

---

## Notes

- T035 (manual test) is the only remaining item — requires running in Xcode with a real microphone.
- The `continuation?.finish()` fix (T008) is the single most impactful change — it unblocks all `for await` hangs.
- The actor conversion (T009) moves segmentation off MainActor — eliminates UI jank during heavy ASR updates.
