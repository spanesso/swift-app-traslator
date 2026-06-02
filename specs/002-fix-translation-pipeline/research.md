# Research: Fix Translation Pipeline

**Date**: 2026-06-01 | **Branch**: `002-fix-translation-pipeline`

---

## Finding 1 — Root Cause: `continuation.finish()` never called in `stop()`

**Decision**: Fix `ContinuousSpeechListener.stop()` to call `continuation?.finish()` before setting `continuation = nil`.

**Evidence**: `stop()` (line 206–217 of `ContinuousSpeechListener.swift`) sets `continuation = nil` without first calling `.finish()`. Swift's `AsyncStream` is terminated only when all references to its `Continuation` are released AND `.finish()` has been called. Dropping the reference (setting to nil) without `.finish()` leaves the stream in an open state — any `for await` loop consuming it blocks indefinitely. This is why tasks hang after the user taps Stop.

**Secondary effect**: Because the for-await in `NLPSegmenterService.processStream` never exits, the `continuation.finish()` at the end of that Task's body is never reached either — so the segmented stream also never closes. The `.translationTask` in SwiftUI then never receives the stream-end signal, leaving the translation engine in a stale state that refuses to re-attach on the next session.

**Rationale**: Calling `.finish()` before nil is a one-line change with no architectural impact.

**Alternatives considered**: Using `onTermination` handler — valid but more complex; the direct `.finish()` call is sufficient.

---

## Finding 2 — Root Cause: Unresolved Merge Conflicts

**Decision**: Resolve all conflicts in favor of the HEAD (develop) version, with targeted corrections.

**Evidence**: Five source files contain unresolved `<<<<<<<`/`=======`/`>>>>>>>` markers:
- `NLPSegmenterService.swift` — two completely different implementations
- `TranscribeAudioUseCase.swift` — `executeBoth()` vs `executeRaw()` + `executeSegmented()`
- `TranscriptionViewModel.swift` — fan-out task vs two sequential tasks on same stream
- `LiveTranscriptionView.swift` — richer pane rendering vs single `scrollableTextView`
- `DependencyContainer.swift` — minor comment conflict

The HEAD version is architecturally superior: it has the correct fan-out, richer NLP segmentation (3-tier cascade), and the correct `.translationTask` lifecycle fix (`taskID` rotation). The main-branch version has the single-consumer `AsyncStream` bug (Finding 3) and a simplistic segmenter.

**Rationale**: Keeping HEAD and discarding main-branch versions eliminates the single-consumer bug and preserves the more sophisticated NLP cascade.

---

## Finding 3 — Root Cause: AsyncStream Single-Consumer Violation

**Decision**: Use `executeBoth()` (already in HEAD) for all recording sessions; remove `executeRaw()` + `executeSegmented()` call path from `startRecording()`.

**Evidence**: The main-branch `startRecording()` calls:
```swift
let rawStream = try await transcribeUseCase.executeRaw()
let uiTask = Task { for await segment in rawStream { ... } }  // consumer 1
let stableStream = transcribeUseCase.executeSegmented(from: rawStream)  // consumer 2
```
`AsyncStream` delivers each element to exactly one awaiting consumer. Two concurrent for-await loops on the same stream race for elements — on average, half the segments go to the UI update and half to the segmenter. The UI shows roughly half the words; the segmenter sees roughly half the segments and produces malformed or missing translations.

**Rationale**: `executeBoth()` creates a pump Task that receives each segment once and yields it to two separate streams. Both consumers see every element.

---

## Finding 4 — Root Cause: `NLPSegmenterService` Runs on MainActor

**Decision**: Convert `NLPSegmenterService` from `final class` to `actor`.

**Evidence**: The project sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` in build settings. This makes all non-annotated types implicitly `@MainActor`. `NLPSegmenterService` is a `final class` with no explicit isolation annotation, so it is `@MainActor`. The `Task { ... }` created inside `processStream`'s `AsyncStream` closure inherits this isolation. Consequently:
- `for await segment in stream` runs on MainActor — each ASR update suspends and resumes the main thread
- `Task.sleep(nanoseconds:)` runs on MainActor — the stability timer occupies a MainActor slot
- NLTokenizer calls in `splitIntoSentences` run on MainActor — CPU-bound work blocks UI

Converting to `actor` moves all state and execution to the actor's own serial executor, which the Swift runtime schedules off the main thread.

**Impact on protocol**: `NLPSegmenterServiceProtocol.processStream` becomes an `async` method. Callers must `await segmenter.processStream(stream)`.

**Alternatives considered**:
- `nonisolated` + `Task.detached` — moves execution off MainActor but leaves mutable state (`committedFullText`, etc.) unprotected from concurrent mutation
- Explicit `@globalActor` — equivalent to actor conversion but more verbose

---

## Finding 5 — `.translationTask` Lifecycle

**Decision**: Keep HEAD's `taskID = UUID()` rotation before `translationConfig` assignment. Document the ordering requirement. No further change needed if `translationRequests` is set before `isRecording = true`.

**Evidence**: SwiftUI's `.translationTask(config)` modifier creates a task when `config` becomes non-nil. Without rotating `.id(taskID)`, SwiftUI detects that the same view identity has a new `config` value and updates the existing task — but the existing task is still consuming the *previous session's* `translationRequests` stream (which was finished). The new stream is ignored.

Rotating `taskID` forces SwiftUI to destroy the previous `.translationTask` subtree entirely and create a fresh one. The new task's closure runs, reads the now-non-nil `viewModel.translationRequests`, and begins consuming.

**Ordering constraint** (already in HEAD, must be preserved):
```swift
taskID = UUID()          // 1. destroy old task subtree
translationConfig = ...  // 2. create new task subtree with fresh stream
```

**Race condition check**: `startRecording()` sets `translationRequests` synchronously on MainActor, then sets `isRecording = true`. SwiftUI's `onChange(of: isRecording)` fires on the next render pass (still MainActor). At that point, `translationRequests` is guaranteed non-nil. The `guard let requests = ...` in the task closure passes. No race.

---

## Finding 6 — Fan-out Pump Task Not Stored

**Decision**: Store the pump Task reference in `TranscribeAudioUseCase` as `private var pumpTask: Task<Void, Never>?`. Cancel it in `stop()`.

**Evidence**: `executeBoth()` creates a `Task.detached { ... }` with no reference. Cancelling `transcriptionTask` in the ViewModel does not cancel the pump. The pump exits only when the source stream finishes (which now happens correctly once Finding 1 is fixed). Storing the reference adds explicit cleanup and makes the lifecycle intent clear.

**Rationale**: Defensive — the pump would self-terminate after the source stream closes, but storing the reference makes teardown deterministic.

---

## Finding 7 — `TranslatorAppApp` ViewModel Lifecycle

**Decision**: Store `TranscriptionViewModel` in `@State` in `TranslatorAppApp`, not constructed on every `body` call.

**Evidence**:
```swift
var body: some Scene {
    WindowGroup {
        LiveTranscriptionView(viewModel: container.makeTranscriptionViewModel())
    }
}
```
`body` is re-evaluated by SwiftUI whenever the scene needs to update. Each evaluation calls `makeTranscriptionViewModel()` which constructs a new instance. The `@Observable` ViewModel from a previous render is discarded, losing all in-progress state.

**Fix**: Either cache in `DependencyContainer` or store in App `@State`:
```swift
@State private var viewModel: TranscriptionViewModel
init() { _viewModel = State(wrappedValue: DependencyContainer().makeTranscriptionViewModel()) }
```

---

## Finding 8 — `QualityMetricsService.isLowQualitySpeech()` Unused

**Decision**: Wire `isLowQualitySpeech()` to the stability timer in `NLPSegmenterService`: when low quality is detected, use a longer stability delay (1.2 s instead of 0.7 s).

**Evidence**: `QualityMetricsService` computes a rich heuristic (revision rate, confidence, fragmentation, WPS) but the result is never read. The original design intent was adaptive delay tuning, which is exactly this use case.

**Integration point**: After each `for await segment` iteration, query `await qualityMetrics.isLowQualitySpeech()` and select the delay value:
```swift
let delay = await qualityMetrics.isLowQualitySpeech() ? 1_200_000_000 : stabilityDelay
```

---

## Finding 9 — `TranslatorState` Incomplete

**Decision**: Add `.permissionDenied` and `.modelUnavailable` to `TranslatorState`.

**Evidence**: FR-010 and SC-006 require descriptive errors for specific failure modes. The current enum has only `.idle`, `.inFlight`, `.error`. Error type is communicated via `errorMessage: String?` which is not machine-readable by the View. Adding specific cases allows the View to show different UI per error without string matching.

---

## Non-Issues (Investigated, No Action)

- **`CryptoKit` import in old segmenter**: Present only in the main-branch version; resolved by taking HEAD version.
- **`handleError()` double-finish race**: `stop()` is called inside `handleError()` which sets `continuation = nil` (after our fix, also calls `.finish()`). If the recognition task callback fires after `stop()` has already finished and nilled the continuation, `continuation?.finish()` is a safe no-op.
- **NLTokenizer per-call instantiation**: A new `NLTokenizer` is created in `splitIntoSentences` on every call. This is acceptable for the current usage frequency (< 1 call/s); caching would be premature optimisation.
