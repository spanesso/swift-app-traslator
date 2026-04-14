# Plan: Real-Time Translation Pipeline Fix & Readability Overhaul

## Context
The app has three compounding failures that make it unreliable for business meetings:
1. **Translations rarely fire** — two confirmed root causes: the `rawStream` from `executeRaw()` is consumed simultaneously by two `for await` loops (AsyncStream is single-consumer, so segments are split unpredictably between UI update and segmentation); and `taskID` in the View is never mutated, so SwiftUI never recreates the `.translationTask` session between recording sessions.
2. **Final phrases are lost** — the stability timer fires 1.4 s after the last segment, but `continuation.finish()` is called immediately when the stream ends; the timer's `yield` lands on a closed continuation and is silently dropped.
3. **Text display is unreadable** — both panes dump all accumulated text as a single `Text` blob.

## Execution Order
Changes must be applied in this sequence (each step can compile independently):

---

## Step 1 — `NLPSegmenterService.swift` (standalone domain fix)

**1a — Replace character-count guard with equality check (line 43)**
- Current: `if currentFullText.count <= lastEmittedFullText.count { continue }`
- New: `if currentFullText == lastEmittedFullText { continue }`
- Reason: ASR corrections that shorten text (e.g., "jumps" → "jump") were permanently silenced.

**1b — Track last-seen text outside the for-loop**
- Add `var lastSeenText: String = ""` before the `for await` loop.
- Inside the loop assign `lastSeenText = currentFullText` on every iteration that passes the equality guard.

**1c — Flush last phrase after loop ends (Bug 3)**
- After `for await` exits, before `continuation.finish()`:
  ```
  stabilityTimer?.cancel()
  if !lastSeenText.isEmpty {
      await processDifferentialText(lastSeenText, isFinal: true, to: continuation)
  }
  continuation.finish()
  ```
- This ensures the last phrase a speaker says is always translated, even though the stream ended before the 1.4 s timer fired.

**1d — Pass `isFinal` into `processDifferentialText` (Bug 5)**
- Change signature to `processDifferentialText(_ newFullText: String, isFinal: Bool, to continuation:)`.
- Update the emission gate: emit if `words.count >= 5` OR `newFullText.hasSuffix(".")` OR (`isFinal == true && words.count >= 2`).
- Update all call sites inside the file (the timer Task and the new flush call above).
- `NLPSegmenterServiceProtocol` signature is **not changed**.

---

## Step 2 — `TranscribeAudioUseCase.swift` + `TranscriptionViewModel.swift` (coordinated, apply together)

### 2a — Add `executeBoth()` to `TranscribeAudioUseCase`

New method: `func executeBoth() async throws -> (raw: AsyncStream<SpeechSegment>, segmented: AsyncStream<String>)`

Internal logic:
1. Call `repository.startTranscription()` **once** → `sourceStream`.
2. Create two independent stream pairs via `AsyncStream.makeStream(of:)`: `(rawOutput, rawCont)` for `SpeechSegment` and `(segInput, segCont)` for `SpeechSegment`.
3. Spawn a detached fan-out Task that iterates `sourceStream` and on each segment calls both `rawCont.yield(segment)` and `segCont.yield(segment)`. On loop exit, finish both continuations.
4. Pass `segInput` into `segmenter.processStream(segInput)` → `segmentedOutput`.
5. Return `(rawOutput, segmentedOutput)`.

Existing `executeRaw()` and `executeSegmented()` are **not removed** (zero regression risk).

### 2b — Update `TranscriptionViewModel.startRecording()`

Replace lines 52-68 (the two-stream logic) with:
1. `let (rawStream, stableStream) = try await transcribeUseCase.executeBoth()`
2. Spawn `uiTask` that iterates `rawStream` → updates `self.currentBuffer = segment.text`.
3. In the parent Task, iterate `stableStream`:
   - `self.translatorState = .inFlight`
   - `self.translationContinuation?.yield(sentence)`
   - `self.emittedPhrases.append(sentence)` (new property, see Step 3)
4. After `stableStream` loop exits, `uiTask.cancel()`.

`stopRecording()` is **not changed** — it calls `transcribeUseCase.stop()` which stops the repository and naturally ends the source stream, which terminates the fan-out pump, which finishes both downstream streams.

---

## Step 3 — `TranscriptionViewModel.swift` (additive properties for UI)

- Add `var emittedPhrases: [String] = []` — populated in Step 2b. Cap at 50 entries (remove from front). Reset to `[]` at start of `startRecording()`.
- Change `private var translatedSentences` → `var translatedSentences` (remove `private`). The `@Observable` macro tracks it for SwiftUI. The existing `translatedBuffer` joined string is kept but the View will no longer read it.

---

## Step 4 — `LiveTranscriptionView.swift` (Bug 2 fix + UI redesign)

### 4a — Fix `taskID` mutation (Bug 2)
In `.onChange(of: viewModel.isRecording)`, when `isRecording == true`, order must be:
1. `taskID = UUID()` ← first (destroys old `.translationTask` subtree)
2. `translationConfig = .init(source: ..., target: ...)` ← second (new subtree picks it up)

### 4b — EN Pane redesign
Replace `scrollableTextView(text: viewModel.currentBuffer, ...)` with an `englishPane()` method:
- **History section:** `ForEach(viewModel.emittedPhrases, id: \.self)` → each phrase as `Text` at 11 pt, `.foregroundStyle(.white.opacity(0.45))`.
- **Live section:** `Text(viewModel.currentBuffer)` at 13 pt semibold, `.foregroundStyle(.green)`, tagged `.id("raw_end")`.
- Auto-scroll to `"raw_end"` on change of `currentBuffer` OR `emittedPhrases.count`.
- Empty state placeholder if both are empty.

### 4c — ES Pane redesign
Replace `scrollableTextView(text: viewModel.translatedBuffer, ...)` with a `spanishPane()` method:
- `ForEach(Array(viewModel.translatedSentences.enumerated()), id: \.offset)` iterates each sentence.
- Non-last sentences: 18 pt `.medium`, `.foregroundStyle(.cyan)`.
- Last sentence: 20 pt `.semibold`, `.foregroundStyle(.white)` — visually highlighted.
- Last sentence's container tagged `.id("tr_end")`.
- Auto-scroll on `.onChange(of: viewModel.translatedSentences.count)`.
- Empty state: `Text("Esperando traducción...")` in `.foregroundStyle(.secondary)`.

### 4d — Remove `scrollableTextView` helper (no longer used)

---

## Critical Files

| File | Step |
|------|------|
| `TranslatorApp/Domain/Services/NLPSegmenterService.swift` | 1 |
| `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift` | 2a |
| `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` | 2b, 3 |
| `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` | 4 |

Files **not touched:** `NLPSegmenterServiceProtocol.swift`, `DependencyContainer.swift`, `ContinuousSpeechListener.swift`, `SpeechRepository.swift`, `RecordButton.swift`.

---

## Verification

1. Build: `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' build`
2. Run the app, press Record, speak 3–4 sentences. Every sentence must appear in the ES pane within ~2 s of finishing.
3. Stop and restart recording. New translation session must work — OSLog must show a new `[UI] Translation engine active and listening` line.
4. Speak a short 2-word phrase as the last thing before stopping. It must appear translated (validates Bug 3 fix).
5. Speak a correction ("I mean… actually I think…") — must not produce duplicate translations.
6. ES pane must show each sentence as a distinct block, newest sentence white/larger, others cyan/regular.
