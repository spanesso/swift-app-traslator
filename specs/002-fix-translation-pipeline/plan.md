# Implementation Plan: Fix Translation Pipeline

**Branch**: `002-fix-translation-pipeline` | **Date**: 2026-06-01 | **Spec**: [spec.md](./spec.md)

## Summary

The transcription → segmentation → translation pipeline is broken by a combination of unresolved merge conflicts, a stream that never terminates on `stop()`, an `AsyncStream` consumed by two readers simultaneously (in the old branch), and the segmentation Task running on the MainActor due to the project-wide `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting. This plan resolves the conflicts, fixes the stream lifecycle, isolates segmentation off the main thread, and tightens the `.translationTask` lifecycle in SwiftUI.

---

## Technical Context

**Language/Version**: Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
**Primary Dependencies**: Speech (SFSpeechRecognizer), AVFoundation, NaturalLanguage (NLTokenizer), Translation (Apple on-device), OSLog — all Apple frameworks, no third-party packages
**Storage**: N/A — in-memory only
**Testing**: XCTest (unit), TranslatorAppUITests (UI — currently scaffold)
**Target Platform**: macOS (single target)
**Project Type**: macOS desktop app
**Performance Goals**: Translation appears within 3 s of phrase end; UI never freezes > 200 ms; all tasks cancel within 2 s of Stop
**Constraints**: Offline-capable (no network); no new dependencies; merge conflicts must be resolved as part of this fix
**Scale/Scope**: Single user, single session; up to 3 consecutive stop/restart cycles without degradation

---

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

Architecture principles taken from CLAUDE.md (project's de-facto constitution):

| Gate | Status | Notes |
|------|--------|-------|
| Clean Architecture: `Presentation → Domain ← Data` | ✅ PASS | No new layer crossings introduced |
| ViewModels never `@StateObject` inside Views | ✅ PASS | ViewModel passed via init; `@Observable` used |
| MainActor rule: capture+detection outside MainActor; UI on MainActor | ⚠️ VIOLATION (current) → FIX REQUIRED | `NLPSegmenterService` is implicitly `@MainActor` due to project setting; must be made nonisolated |
| No new dependencies | ✅ PASS | Only Apple frameworks |
| Max 250 lines per Swift file | ✅ PASS | Will be checked per-file post-edit |
| Swift 6 strict concurrency — build without concurrency warnings | ⚠️ MUST VERIFY | Merge conflict resolution may surface new warnings |
| Domain layer: no AVFoundation/UIKit/SwiftUI/OpenCV | ✅ PASS | Domain files unchanged in scope |
| OpenCV only in .mm | N/A | Not used in this project |

**Pre-design verdict**: One violation to fix (actor isolation). Proceed.

---

## Project Structure

### Documentation (this feature)

```text
specs/002-fix-translation-pipeline/
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
├── quickstart.md        ← Phase 1 output
└── tasks.md             ← Phase 2 output (/speckit.tasks)
```

### Source Code (repository root)

```text
TranslatorApp/
├── App/
│   ├── TranslatorAppApp.swift          ← fix: cache ViewModel in @State
│   └── DependencyContainer.swift       ← resolve conflict (minor)
├── Data/
│   ├── ContinuousSpeechListener.swift  ← fix: call continuation.finish() in stop()
│   └── Respository/
│       └── SpeechRepository.swift      ← no changes needed
├── Domain/
│   ├── Entities/
│   │   ├── SpeechSegment.swift         ← no changes needed
│   │   ├── TranslatorState.swift       ← extend: add .permissionDenied, .modelUnavailable
│   │   └── QualitySnapshot.swift       ← no changes needed
│   ├── Interfaces/
│   │   ├── SpeechRepositoryProtocol.swift     ← no changes needed
│   │   └── NLPSegmenterServiceProtocol.swift  ← no changes needed
│   ├── Services/
│   │   ├── NLPSegmenterService.swift    ← resolve conflict; fix actor isolation; keep HEAD logic
│   │   ├── QualityMetricsService.swift  ← no changes needed
│   │   └── TranslationContextWindow.swift ← no changes needed
│   └── UseCases/
│       └── TranscribeAudioUseCase.swift ← resolve conflict; keep executeBoth(); store pump Task
└── Presentation/
    ├── ViewModels/
    │   └── TranscriptionViewModel.swift ← resolve conflict; fix startRecording/stopRecording
    └── Views/
        ├── LiveTranscriptionView.swift  ← resolve conflict; fix .translationTask lifecycle
        └── RecordButton.swift           ← no changes needed
```

---

## Phase 0: Research

See [research.md](./research.md) for full findings. Summary of decisions:

### Decision 1 — Fan-out strategy: pump Task with two continuations

**Decision**: Keep `executeBoth()` from the HEAD/develop branch. It creates a single source stream from the repository and fans out via a detached `Task` that yields each segment to two separate `AsyncStream.Continuation` objects.

**Rationale**: `AsyncStream` is single-consumer by design. The main-branch approach of passing the same stream to two `for await` loops distributes elements unpredictably between consumers — some segments go to the UI, the rest to the segmenter. The fan-out pump is the standard fix.

**Enhancement**: Store the pump Task in `TranscribeAudioUseCase` so it can be explicitly cancelled on `stop()`.

**Alternatives considered**:
- `AsyncChannel` from swift-async-algorithms — rejected (new dependency, violates no-external-dependencies rule)
- Single consumer + re-broadcast via `AsyncStream.makeStream` in the caller — equivalent to current fan-out, no benefit

---

### Decision 2 — Stream termination: `continuation.finish()` before nil

**Decision**: In `ContinuousSpeechListener.stop()`, call `continuation?.finish()` **before** setting `continuation = nil`.

**Rationale**: `AsyncStream` terminates when its `Continuation` is `.finish()`-ed. Setting the continuation to `nil` without finishing it leaves any `for await` loop waiting indefinitely — the loop never receives a termination signal. This is the root cause of tasks hanging after Stop.

**Additional fix**: The recognition task callback dispatches `Task { await self.handleError() }` — once the audio is stopped, a racing error callback can attempt to finish an already-nilled continuation. Guard against double-finish by using a `finished` flag or the `onTermination` handler.

---

### Decision 3 — Actor isolation for `NLPSegmenterService`

**Decision**: Add `nonisolated` to the `processStream` method and use `Task.detached` for the internal processing loop, or annotate the class with `@unchecked Sendable` and route the inner Task to a background priority. Preferred: convert to `actor` so state mutation is automatically safe.

**Rationale**: With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `NLPSegmenterService` (a `final class`) runs all its methods on the MainActor. The `Task { ... }` inside `processStream` also runs on MainActor. This means every `for await`, `Task.sleep`, and NLTokenizer call blocks the UI. Observed symptoms: UI jank, translation lag, and `.onChange` handlers delayed.

**Chosen fix**: Convert `NLPSegmenterService` to an `actor`. This:
- Moves all state to the actor's serial executor (off MainActor)
- Eliminates data races on `committedFullText`, `lastSeenFullText`, etc.
- Is forward-compatible with Swift 6 strict concurrency

**Impact on callers**: `processStream` becomes `async` — callers use `await segmenter.processStream(stream)`.

---

### Decision 4 — `.translationTask` lifecycle

**Decision**: Rotate `taskID` **then** assign `translationConfig` in `onChange(of: isRecording)` when `isRecording` becomes `true`. This ordering (already present in HEAD) forces SwiftUI to destroy the old `.translationTask` subtree before attaching the new config.

**Enhancement**: Remove the `guard let requests = viewModel.translationRequests else { return }` guard and instead have the task wait for a non-nil value. Alternatively, pass the stream directly by capturing it in a `@State` local before setting `isRecording`, making the task closure's captured value guaranteed non-nil.

**Chosen approach**: Use `AsyncStream.makeStream` in `startRecording()` and pass the continuation and stream to the view via two separate `@Published`-equivalent observable properties. The `.translationTask` closure captures `requests` at call site rather than reading a property — this eliminates the nil-check race entirely.

**Concretely**: The ViewModel creates the stream before setting `isRecording = true`. By the time `onChange` fires and the task starts (both on MainActor, sequentially), `translationRequests` is already non-nil.

---

### Decision 5 — `TranslatorAppApp` ViewModel lifecycle

**Decision**: Change `makeTranscriptionViewModel()` to return a cached `@State` instance, or store the ViewModel directly in `@State` in `TranslatorAppApp`.

**Rationale**: `container.makeTranscriptionViewModel()` is called in the `body` computed property, which SwiftUI re-evaluates on every render cycle. Each call creates a new `TranscriptionViewModel` instance, throwing away the previous one's state mid-session.

**Fix**:
```swift
@State private var viewModel: TranscriptionViewModel  // initialised once
```

---

### Decision 6 — `TranslatorState` extension

**Decision**: Add two new cases to `TranslatorState`:
- `.permissionDenied` — microphone or speech recognition authorization refused
- `.modelUnavailable` — on-device translation model not downloaded

**Rationale**: FR-010 requires descriptive errors. Without dedicated states, the ViewModel uses a string `errorMessage` which is not machine-checkable by the View. Adding states allows the View to show tailored UI per error type.

---

### Decision 7 — Wire `QualityMetricsService.isLowQualitySpeech()`

**Decision**: In `NLPSegmenterService`, after each commit, query `isLowQualitySpeech()` asynchronously. If true, reduce the stability timer from 0.7 s to 1.2 s to allow the ASR more time to stabilise before emitting partial phrases.

**Rationale**: `isLowQualitySpeech()` exists and is computed correctly but is never consumed (noted as a known gap). Wiring it to the stability timer is the minimal integration that provides adaptive behaviour without scope creep.

---

## Phase 1: Design

### Data Model

See [data-model.md](./data-model.md) for entity definitions.

Key state transitions for `SessionState` (maps to `TranslatorState` + `isRecording`):

```text
idle
  → [user taps Record] → authorising
  → [permission granted] → recording
  → [permission denied] → permissionDenied (error shown)
recording
  → [phrase detected] → inFlight (translation requested)
  → [translation arrives] → recording (back to listening)
  → [user taps Stop] → stopping
  → [ASR error] → error
stopping
  → [all tasks cancelled] → idle
inFlight
  → [translation done] → recording
  → [model unavailable] → modelUnavailable (error shown)
```

### Interface Contracts

No external API surface. Internal contracts:

**`SpeechRepositoryProtocol`** (unchanged):
```swift
func startTranscription() async throws -> AsyncStream<SpeechSegment>
func stopTranscription() async
```

**`NLPSegmenterServiceProtocol`** (updated — now async):
```swift
func processStream(_ stream: AsyncStream<SpeechSegment>) async -> AsyncStream<String>
```

**`TranscribeAudioUseCase`** (updated):
```swift
func executeBoth() async throws -> (raw: AsyncStream<SpeechSegment>, segmented: AsyncStream<String>)
func stop() async
```

**`TranscriptionViewModel`** (updated observable properties):
```swift
var currentBuffer: String          // live EN tail (uncommitted text)
var emittedPhrases: [String]       // committed EN phrases
var translatedSentences: [String]  // translated ES phrases
var isRecording: Bool
var translatorState: TranslatorState
var translationRequests: AsyncStream<String>?  // consumed by .translationTask
```

---

## Complexity Tracking

| Item | Why Needed | Simpler Alternative Rejected Because |
|------|------------|-------------------------------------|
| Fan-out pump Task in `executeBoth()` | AsyncStream is single-consumer; UI and segmenter both need every segment | Sharing the stream distributes elements unpredictably — tested in main branch, confirmed broken |
| Actor conversion of `NLPSegmenterService` | `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` makes the class block UI thread | `nonisolated` + `Task.detached` achieves the same isolation but leaves state unprotected; actor is cleaner and Swift 6-safe |
| `taskID` rotation before `translationConfig` assignment | Forces SwiftUI to destroy stale `.translationTask` subtree | Without rotation, the old task's `for await` continues on the new (wrong) stream |
