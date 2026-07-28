---
description: "Task list for feature 006-fix-asr-word-loss"
---

# Tasks: Reconocimiento de voz sin pérdida de palabras

**Input**: Design documents from `/specs/006-fix-asr-word-loss/`
**Prerequisites**: plan.md, spec.md, research.md, data-model.md, contracts/

**Tests**: The evaluation harness (WER) is an explicit spec requirement (US3, SC-004/SC-010), so
harness/measurement tasks are included. Unit-test tasks beyond that are only added where the spec
demands a measurable guarantee (SC-001, SC-003, SC-007, SC-009).

**Organization**: Tasks are grouped by user story. Phase order follows the **delivery sequence in
plan.md** (measurement gate → P1 symptom fix → WhisperKit → SpeechAnalyzer), which intentionally
runs US3 (P2, measurement) before US1/US2 (P1) because it gates their validation.

**Build**: pure Xcode project. Build/run in Xcode (⌘R). CLI:
`xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=iOS,name=<device>' build`.

## Path Conventions

Mobile (single iOS app target). Source under `TranslatorApp/`; evaluation sources under
`TranslatorAppEvaluationTests/`; Xcode project `TranslatorApp.xcodeproj`.

---

## Phase 1: Setup (Shared Infrastructure)

**Purpose**: Diagnostic + measurement scaffolding so every later change is verifiable.

- [ ] T001 Create the `TranslatorAppEvaluationTests` Xcode test target (XCTest/Swift Testing, iOS) in `TranslatorApp.xcodeproj`, add all existing sources under `TranslatorAppEvaluationTests/` (Evaluation/, Tests/, Tools/) as members, and add it to the `TranslatorApp` scheme so `xcodebuild test -only-testing:TranslatorAppEvaluationTests/...` runs (005 T003)
- [X] T002 Add an unambiguous engine-selection log line at the end of engine selection in `TranslatorApp/App/DependencyContainer.swift` (`:48–66`): OSLog subsystem `com.spanesso.TraslatorApp`, category `Container`, message `"[Container] engine=\(engineId)"`
- [ ] T003 Verify green baseline build/test: `xcodebuild -scheme TranslatorApp build` and `xcodebuild test -only-testing:TranslatorAppEvaluationTests/EdAccSubsetEvaluation` (XCTSkip when corpus absent) both succeed before any behavioral change

**Checkpoint**: Evaluation target runs via `xcodebuild test`; the active engine is visible in OSLog.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Shared audio primitives and cleanups consumed by multiple engine fixes.

**⚠️ CRITICAL**: T004 blocks US1 (H1); T005 de-duplicates the filter used by US2/US4.

- [X] T004 Create `TranslatorApp/Data/Audio/AudioRingBuffer.swift` per `contracts/AudioRingBuffer.swift`: actor-local, `AVFoundation`+`Foundation` only, `capacitySeconds ≈ 1.5`, `append(_:)` evicts beyond capacity, `drain() -> [AVAudioPCMBuffer]` returns oldest-first and clears, `reset()`; buffers stored in the tap's native format (no resampling); ≤250 lines
- [X] T005 Rename `TranslatorApp/Data/Audio/VADGate.swift` → `EmptySegmentFilter.swift` (type `EmptySegmentFilter`) per `contracts/EmptySegmentFilter.swift`, and remove the DUPLICATE application: keep it in `TranslatorApp/Data/SpeechRepository.swift` (`:27`) and delete the in-engine call in `TranslatorApp/Data/SpeechEngines/WhisperKitEngine.swift` (`:51`); update all references

**Checkpoint**: Ring buffer available to engines; the empty-segment filter is applied exactly once.

---

## Phase 3: User Story 3 - Medir antes/después (Priority: P2) 🎯 GATE

**Goal**: Reproducible WER-per-accent baseline so every subsequent change is validated, not guessed.

**Independent Test**: Run the harness over a mini-corpus and obtain a per-accent WER report,
reproducible across runs; confirm the active engine from OSLog on a test device.

- [ ] T006 [US3] Confirm the wired evaluation harness compiles and runs end-to-end: `EvaluationHarness.swift`, `WERCalculator.swift`, `EntityExtractor.swift`, `EvaluationReport.swift`, `EvaluationDelta.swift`, `EvaluationCorpusManifest.swift` all resolve within the new target (fix any `@testable import TranslatorApp` visibility gaps)
- [ ] T007 [P] [US3] Provide a 5-item smoke `manifest.json` per `TranslatorAppEvaluationTests/Corpora/README.md` and run `TranslatorAppEvaluationTests/Tests/EdAccSubsetEvaluation.swift`; record the emitted JSON as the **Phase-0 baseline** under `evaluation-reports/006-baseline@<buildId>.json`
- [ ] T008 [P] [US3] Run `TranslatorAppEvaluationTests/Tests/ReproducibilityTest.swift` and confirm two runs agree on headline WER within ±0.5 pp (SC-004)
- [ ] T009 [US3] On a physical test device, launch the app and capture the `[Container] engine=…` OSLog line; document which engine runs by default (expected `legacyAppleSFSpeech`)

**Checkpoint**: Baseline WER-per-accent recorded and reproducible; running engine confirmed. This
phase gates the validation of US1 and US2.

---

## Phase 4: User Story 1 - No perder palabras al retomar (Priority: P1)

**Goal**: Eliminate audio loss at recognizer restart (pauses and the ~60 s cap) and at session start.

**Independent Test**: Read a scripted passage with pauses every 10–15 s and a run past 60 s; no word
immediately after a pause or the restart is missing (SC-001).

- [X] T010 [US1] In `TranslatorApp/Data/ContinuousSpeechListener.swift`, instantiate an `AudioRingBuffer` and append every tap buffer to it inside the tap callback (`:62–107`), alongside the existing request append
- [X] T011 [US1] Rework `restartRecognition()` in `TranslatorApp/Data/ContinuousSpeechListener.swift` (`:126–157`) to the no-loss order: (1) build+start the NEW `SFSpeechAudioBufferRecognitionRequest`, (2) `drain()` the ring buffer and append its frames to the new request, (3) redirect the live tap to the new request, (4) end/cancel the OLD request last — keeping the audio engine + tap running as today
- [X] T012 [US1] Verify the ~65 s watchdog path (`:114–122`) and the `isFinal||error` trigger (`:98–104`) route through the reworked restart so the ~60 s boundary loses no words; add an OSLog `Speech` debug line counting carried-over frames per restart
- [X] T013 [US1] Fix the continuation race in `TranslatorApp/Data/SpeechEngines/AppleSpeechAnalyzerEngine.swift` (`:37–39`): assign the continuation SYNCHRONOUSLY inside the `AsyncStream { cont in ... }` builder (mirror `ContinuousSpeechListener.swift:47`) before starting recognition, removing the detached `Task { await setContinuation }` (H5)
- [ ] T014 [US1] Consolidate the two classic `SFSpeechRecognizer` implementations: pick one actor as canonical (retain the synchronous-continuation lifecycle + watchdog + ring buffer, graft the token mapping from `AppleSpeechAnalyzerEngine.swift:84–90`), route both `LegacySFSpeechEngine` and the `.appleSpeechAnalyzer` selection to it, and retire the duplicate; keep each file ≤250 lines (split into `+Restart.swift` if needed)
- [ ] T015 [US1] Validate SC-001: scripted-passage device test (pauses + >60 s) shows zero restart-attributable word loss; re-run the harness and confirm no WER regression vs the T007 baseline

**Checkpoint**: The engine that runs today no longer drops words around pauses, the ~60 s restart, or session start.

---

## Phase 5: User Story 2 - Reconocer voz con acento/baja/lejana (Priority: P1)

**Goal**: Improve recognition accuracy for accented, quiet, and distant speech on the current engine.

**Independent Test**: Read the same passage at normal/low volume and ~1 m; harness WER improves for
non-native + low-voice groups with no native regression beyond noise (SC-002/SC-010); punctuation appears.

- [X] T016 [US2] Change `AVAudioSession` mode from `.measurement` to `.spokenAudio` (fallback `.default`) in `TranslatorApp/Data/ContinuousSpeechListener.swift` (`:55–59`) and in the consolidated classic engine (was `AppleSpeechAnalyzerEngine`); keep category `.record` (H2)
- [X] T017 [US2] Configure the recognition request in `TranslatorApp/Data/ContinuousSpeechListener.swift` (`:62–107`): set `taskHint = .dictation`, `addsPunctuation = true`, and `contextualStrings` from a new configurable domain-vocabulary constant (H3)
- [X] T018 [P] [US2] In `TranslatorApp/Domain/Services/QualityMetricsService.swift`, stop feeding partial-result confidence (reported 0.0) into `recordConfidence` (`:56–60`); count only final/non-zero confidence so `isLowQualitySpeech()` (`:112`) is not tripped by default (H4)
- [X] T019 [P] [US2] In `TranslatorApp/Domain/Services/NLPSegmenterService.swift` (`:49–54`), allow ≤1-word segments to emit when the utterance is complete (terminator/stability flush), not only on `isFinal`; verify against `emitIfViable` `minShortPhraseWords` (`:151`) (SC-003)
- [X] T020 [P] [US2] Bind confidence to the phrase in `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`: carry the emitting segment's confidence through to the `TranslationRequest` (`:178`) instead of reading the mutable `latestSegmentConfidence` (`:65,164`) (SC-006)
- [ ] T021 [US2] Validate SC-002/SC-003/SC-010: run the harness at normal/low/distant conditions; confirm WER improvement for non-native + low-voice groups, native WER within noise of baseline, one-word utterances present, and punctuation in the EN transcript

**Checkpoint**: MVP complete — the current engine no longer "se queda corta" (US1) nor "reconoce mal" (US2).

---

## Phase 6: User Story 4 - WhisperKit premium usable en vivo (Priority: P3)

**Goal**: Make the premium accent engine actually run on device with live translation and real model management.

**Independent Test**: On an A17 Pro device, select WhisperKit, complete model preparation with visible
progress, dictate accented speech and see live ES translation before stopping; 2-minute session no freeze.

- [ ] T022 [US4] Fix the tap format (W1, blocking) in `TranslatorApp/Data/SpeechEngines/WhisperKitEngine.swift` (`:75–84`): install the tap at the input node's NATIVE format and convert to 16 kHz mono Float32 via `AVAudioConverter` before appending to the Whisper buffer
- [ ] T023 [US4] Replace the hand-rolled 2 s loop (`:101–117`) with WhisperKit's `AudioStreamTranscriber` (sliding windows, `chunkingStrategy: .vad`, previous-text context); bound any residual buffer so it does not grow unbounded (W2/W6)
- [ ] T024 [US4] Emit `AudioStreamTranscriber` CONFIRMED segments as `isFinal: true` (not `isHypothesis`) so they pass `TranscribeAudioUseCase.swift:48` and reach the segmenter/translation live; keep interim results as hypotheses for raw display (W3)
- [ ] T025 [US4] Reconcile `NLPSegmenterService.pendingHypothesis` (`:28,56–61`): now that confirmed segments arrive as final, either consume it correctly or remove it as dead code
- [ ] T026 [US4] Remove/relax `firstTokenLogProbThreshold` in `TranslatorApp/Data/SpeechEngines/WhisperKitEngine.swift` (`:126`, currently `-1.5`) and validate on the accented corpus that legitimate windows are not suppressed (W5)
- [ ] T027 [US4] Unify model management (W4): initialize `WhisperKit` with a `modelFolder`, and either (a) use WhisperKit's built-in download with a progress callback wired to `ModelInstallState`, or (b) fix `TranslatorApp/Data/Coordinators/BackgroundAssetsCoordinator.swift` (`:92–106`) to use the correct `whisperkit-coreml` URL layout, UNZIP the artifact, and only set `whsk.installed = true` after the model verifiably loads
- [ ] T028 [US4] Preload the WhisperKit model when the engine is SELECTED (in `DependencyContainer`/engine-select flow), never on record; surface progress via the existing `ModelInstallState` UI (`EnginePreferenceView`, `LiveTranscriptionView`) (SC-008)
- [ ] T029 [US4] Pin the WhisperKit SPM package to a released version (not `branch main`) in `TranslatorApp.xcodeproj` / `Package.resolved`; record the resolved version in a comment in `DependencyContainer.swift` (005 T001)
- [ ] T030 [P] [US4] (optional) Activate `EngineId.whisperKitSmall` as a harness-comparable candidate and record `small`/`distil` vs `large-v3-turbo` WER-vs-latency to justify the shipped model
- [ ] T031 [US4] Validate SC-007/SC-008 on device: capture starts without a format crash; confirmed segments translate live; 2-minute session no freeze/backlog; model preloaded with visible progress

**Checkpoint**: WhisperKit contributes live, accurate transcription for difficult accents on supported hardware.

---

## Phase 7: User Story 5 - SpeechAnalyzer iOS 26 como Tier 0 (Priority: P3)

**Goal**: Adopt the real iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` to remove the ~60 s cap and restarts at the root.

**Independent Test**: On an iOS 26 device, a 5-minute continuous session with pauses produces no
restarts and no word loss (SC-009); non-supporting devices fall back transparently.

- [ ] T032 [US5] Create `TranslatorApp/Data/SpeechEngines/SpeechAnalyzerEngine.swift` conforming to `SpeechEngineProtocol`, using the real `SpeechAnalyzer`/`SpeechTranscriber` API (guarded by `#available`/`DeviceCapabilities.supportsEnhancedFrameworks`), emitting `SpeechSegment`s with token detail; ≤250 lines
- [ ] T033 [US5] Add a `speechAnalyzer` case to `TranslatorApp/Domain/Entities/EngineId.swift` and map the engine to it
- [ ] T034 [US5] Wire Tier-0 selection in `TranslatorApp/App/DependencyContainer.swift` (`:48–66`): when `supportsEnhancedFrameworks` (and not `.appleOnly`), select `SpeechAnalyzerEngine` as default; else fall through to WhisperKit (A17 Pro + model) or the consolidated classic engine
- [ ] T035 [US5] Validate SC-009 on an iOS 26 device: 5-minute continuous session with pauses, no restarts, no word loss; confirm OSLog shows `speechAnalyzer` selected and a non-supporting device falls back

**Checkpoint**: On modern devices the restart machinery (root of H1) is gone; all engines coexist behind one protocol.

---

## Phase 8: Polish & Cross-Cutting Concerns

**Purpose**: Consistency, docs, and regression protection across stories.

- [ ] T036 [P] Update `CLAUDE.md` (Data Layer / Key Design Decisions) to reflect: iOS target, the ring-buffer restart fix, `.spokenAudio` mode, consolidated classic engine, `EmptySegmentFilter` rename, and the real `SpeechAnalyzer` Tier 0
- [ ] T037 [P] Confirm Clean Architecture + Swift-6 concurrency gates: Domain still imports only Foundation/CoreGraphics/simd/CoreMedia, no `@StateObject` in Views, no `@unchecked Sendable`, all touched files ≤250 lines
- [ ] T038 Run full `quickstart.md` validation across Phases 0–3 on device
- [ ] T039 Regression guard: re-run the evaluation harness and `evaluation-delta` against the T007 baseline; confirm SC-010 (no per-accent WER regression beyond noise) for the whole feature

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: no dependencies — start immediately.
- **Foundational (Phase 2)**: after Setup. T004 blocks US1; T005 blocks US4 cleanup.
- **US3 measurement (Phase 3)**: after Setup; **gates validation** of US1/US2 (T015, T021 compare to T007 baseline).
- **US1 (Phase 4)**: after Foundational (needs T004 ring buffer).
- **US2 (Phase 5)**: after Foundational; largely independent of US1 (different concerns), but both edit `ContinuousSpeechListener.swift` — sequence T010–T012 before T016–T017 to avoid conflicts.
- **US4 (Phase 6)**: after Foundational (needs T005); independent of US1/US2.
- **US5 (Phase 7)**: after Foundational; independent; complements US1 (removes restart need on modern devices).
- **Polish (Phase 8)**: after all targeted stories.

### Within Each User Story

- Models/primitives before services before UI.
- Validation task (SC check) is last in each story phase.

### Parallel Opportunities

- Setup: T001 and (after) T002 are sequential-ish; T003 gates.
- US2: T018, T019, T020 are `[P]` (different files: QualityMetricsService, NLPSegmenterService, TranscriptionViewModel).
- US4: T030 is `[P]` (measurement only).
- Polish: T036, T037 `[P]`.
- Different developers can take US4 and US5 in parallel once Foundational is done.

---

## Parallel Example: User Story 2

```bash
# After T016/T017 (both touch ContinuousSpeechListener), run these together:
Task: "T018 exclude partial confidence in QualityMetricsService.swift"
Task: "T019 allow 1-word emit in NLPSegmenterService.swift"
Task: "T020 bind confidence to phrase in TranscriptionViewModel.swift"
```

---

## Implementation Strategy

### MVP (recommended scope for this feature)

1. Phase 1 Setup → Phase 2 Foundational → Phase 3 US3 (baseline) → Phase 4 US1 → Phase 5 US2.
2. **STOP and VALIDATE**: SC-001 (zero restart loss) + SC-002/SC-003 (accuracy) against the baseline.
3. This delivers the entire reported symptom fix ("se queda corta" + "no reconoce bien") on the engine that runs today.

### Incremental Delivery

- MVP (above) ships the 🔴 high-priority fix.
- US4 (WhisperKit) and US5 (SpeechAnalyzer) are 🟡/🟠 and may be split into separate features
  (`007`/`008`) if scheduling pressure appears — see plan.md Open Questions.

---

## Notes

- `[P]` = different files, no dependencies.
- `[US#]` maps each task to its spec user story for traceability.
- Every behavioral change is gated by the harness baseline (T007) — measure, then change, then re-measure.
- Per project rule: **no commits/branches without the user's go-ahead**; the optional `after_tasks`
  auto-commit hook is not executed automatically.
- File-size rule (≤250 lines) applies to T014, T022–T024, T032 — split with `+Suffix.swift` if exceeded.

---

## Implementation status — 006 MVP (branch `006-fix-asr-word-loss`)

**Done and compiled** (`xcodebuild ... -destination 'platform=iOS Simulator,name=iPhone 17 Pro'` → BUILD SUCCEEDED, 0 concurrency warnings):
- Foundational: T004 (`AudioRingBuffer`), T005 (`VADGate`→`EmptySegmentFilter`, duplicate application removed).
- US1: T010, T011 (no-loss restart), T012 (carry-over log + superseded-request guard), T013 (H5 sync continuation).
- US2: T016 (`.default` audio mode), T017 (dictation hint + punctuation), T018 (H4 final-only confidence), T019 (1-word emit), T020 (confidence threaded via new `SegmentedPhrase` through segmenter → use case → ViewModel).
- T002 (canonical engine log).

**Design deviations (intentional):**
- **T013 extended:** the H1 no-loss restart + `.default` mode + request config were applied to **both** classic engines (`ContinuousSpeechListener` AND `AppleSpeechAnalyzerEngine`), since both carried the defect.
- **T014 DEFERRED:** the two classic engines were **individually fixed** rather than merged/deleted. Consolidation reroutes DI and removes a file — high risk without the integration tests from Phase 0/US3, which are not yet wired. Revisit after T001/T006–T009.
- **H3 `contextualStrings`:** wired as an empty, clearly-marked configurable constant (`contextualVocabulary`) — no domain lexicon guessed, since wrong terms would hurt accuracy.

**Not done — needs your Xcode / a device / a corpus (cannot be done headless):**
- T001, T003 (create the evaluation test target in Xcode; new-target `.pbxproj` surgery).
- T006–T009 (harness run + baseline WER + on-device engine confirmation).
- T015, T021 (SC-001/SC-002/SC-003 device validation against the T007 baseline).
- Phases 6–7 (WhisperKit W1–W6, SpeechAnalyzer) and Polish — out of MVP scope.

**Files changed:** `AudioRingBuffer.swift` (new), `EmptySegmentFilter.swift` (renamed), `ContinuousSpeechListener.swift`, `AppleSpeechAnalyzerEngine.swift`, `WhisperKitEngine.swift`, `SpeechRepository.swift`, `QualityMetricsService.swift`, `NLPSegmenterService.swift`, `NLPSegmenterServiceProtocol.swift`, `TranscribeAudioUseCase.swift`, `TranscriptionViewModel.swift`, `DependencyContainer.swift`.
