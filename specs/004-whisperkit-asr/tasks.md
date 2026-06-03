# Tasks: WhisperKit ASR — Accent-Robust Speech Recognition

**Input**: Design documents from `specs/004-whisperkit-asr/`  
**Prerequisites**: plan.md ✓, spec.md ✓, research.md ✓, data-model.md ✓, contracts/ ✓, quickstart.md ✓

**Tests**: No test tasks generated — spec does not request TDD.  
**Organization**: Tasks are grouped by user story for independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4 map to spec.md stories)
- All file paths are relative to `TranslatorApp/`

---

## Phase 1: Setup (Non-negotiable prerequisites)

**Purpose**: One-line locale fix and Domain entity change — zero risk, zero architecture impact.

- [X] T001 Change locale identifier from `"en-US"` to `"en"` in `Data/ContinuousSpeechListener.swift` (find the `SFSpeechRecognizer(locale:)` initializer — one character change)
- [X] T002 Add `case modelDownloading(progress: Double)` to `Domain/Entities/TranslatorState.swift`, update any exhaustive switch statements in existing files that already switch on TranslatorState (add a stub `case .modelDownloading: break` where needed to fix compile errors)

**⚠️ User action required before Phase 2**: In Xcode → File → Add Package Dependencies → paste `https://github.com/argmaxinc/argmax-oss-swift` → add to target `TranslatorApp`. Without this the WhisperKit import will fail.

---

## Phase 2: Foundational — WhisperKit Data Layer

**Purpose**: Core Data-layer actors. MUST complete before any user story can function.

**⚠️ CRITICAL**: No user story work can begin until this phase is complete. These tasks form the entire ASR backend.

- [X] T003 Create `Data/WhisperModelManager.swift` — Swift `actor` that: (1) detects Apple Silicon via `sysctlbyname("hw.optional.arm64", ...)` in a `private static func isAppleSilicon() -> Bool`; (2) exposes `let downloadProgress: AsyncStream<Double>` and matching `private var progressContinuation`; (3) stores `private var loadedKit: WhisperKit?` and `private var loadTask: Task<WhisperKit, Error>?` for caching and deduplication; (4) implements `func loadModel() async throws -> WhisperKit` with state machine: check `loadedKit` → return cached, check `loadTask` → await existing, else start new task that calls `WhisperKit.download(variant: modelVariant, progressCallback:)` then `WhisperKit(WhisperKitConfig(model: modelVariant))`; (5) reports each progress callback value to `progressContinuation.yield(fraction)`; (6) throws `WhisperASRError.unsupportedHardware` if Intel Mac detected; (7) implements `func cancelLoading() async` that cancels `loadTask` and resets state; (8) defines `enum WhisperASRError: Error` with cases `unsupportedHardware`, `downloadFailed(Error)`, `modelLoadFailed(Error)`, `audioEngineSetupFailed(Error)`; use OSLog category `"WhisperASR"`. Max 250 lines.

- [X] T004 Create `Data/WhisperSpeechListener.swift` — Swift `actor` that: (1) holds `private let modelManager: WhisperModelManager` injected via `init`; (2) holds `private var continuation: AsyncStream<SpeechSegment>.Continuation?`, `private var transcriber: AudioStreamTranscriber?`, `private var audioEngine: AVAudioEngine?`, `private var watchdogTask: Task<Void, Never>?`; (3) implements `func start() async throws -> AsyncStream<SpeechSegment>` that calls `modelManager.loadModel()`, then configures `AVAudioEngine` at 16 kHz mono Float32, then creates `AudioStreamTranscriber` with the WhisperKit components (audioEncoder, featureExtractor, segmentSeeker, textDecoder, tokenizer) and a segment callback that maps `confirmedSegments` → `SpeechSegment(text:, isFinal: true, confidence: confidenceFrom(segment))` and `unconfirmedSegments` → `SpeechSegment(text:, isFinal: false, confidence: 0.5)`, starts `try await transcriber.startStreamTranscription()`, calls `scheduleWatchdog()`; (4) implements `func stop() async` that cancels watchdog, stops transcriber and audio engine, calls `continuation?.finish()`, sets continuation to nil; (5) implements `private func scheduleWatchdog()` that cancels old watchdog and starts a new `Task` sleeping 30 s then calling `restartAudioPipeline()` if not cancelled; (6) implements `private func restartAudioPipeline() async` that stops the transcriber/engine, waits 200 ms, restarts engine + transcriber, reschedules watchdog — WITHOUT calling `continuation.finish()` (stream stays alive); (7) implements `private func confidenceFrom(_ segment: TranscriptionSegment) -> Float` using `exp(Float(segment.avgLogProb ?? -1.0))` clamped to 0.0...1.0. Use OSLog category `"WhisperASR"`. If file exceeds 250 lines split AVAudioEngine setup into `Data/WhisperSpeechListener+Audio.swift`.

- [X] T005 [P] Create `Data/Repository/WhisperSpeechRepository.swift` — `final class WhisperSpeechRepository: SpeechRepositoryProtocol` that holds `private let listener: WhisperSpeechListener` and implements `func startTranscription() async throws -> AsyncStream<SpeechSegment> { try await listener.start() }` and `func stopTranscription() async { await listener.stop() }`. No imports beyond Foundation. ~20 lines.

- [X] T006 Update `App/DependencyContainer.swift` — add `private static func isAppleSilicon() -> Bool` (same sysctlbyname check as WhisperModelManager, used to choose backend at init), add `private let usesWhisper: Bool` computed from the above, add `private var whisperModelManager: WhisperModelManager?` property; in `init()` branch on `usesWhisper`: if true create `WhisperModelManager`, `WhisperSpeechListener(modelManager:)`, `WhisperSpeechRepository(listener:)` and assign to `speechRepository`; if false keep existing `ContinuousSpeechListener` + `SpeechRepository` path. Keep both paths compilable — do not delete `ContinuousSpeechListener`. Ensure `whisperModelManager` is stored as a property so it stays alive for the session.

**Checkpoint**: WhisperKit backend is wired. App can launch. Intel Mac falls back silently. WhisperKit path will crash at Record time until Phase 3 binds the progress stream.

---

## Phase 3: User Story 1 — First Launch Model Download (Priority: P1) 🎯 MVP

**Goal**: On first launch the user sees a download progress indicator. When download completes, transcription starts automatically without any user action.

**Independent Test**: On a clean install (or after deleting `~/Documents/huggingface/models--argmaxinc--whisperkit-coreml/`), open the app, press Record, observe a ProgressView with percentage text appear in the Spanish pane. When it reaches 100%, it disappears and transcription begins — without pressing Record again.

### Implementation

- [X] T007 [P] [US1] Update `Presentation/ViewModels/TranscriptionViewModel.swift` — add `func updateDownloadProgress(_ progress: Double) { translatorState = .modelDownloading(progress: progress) }` (MainActor method, already @MainActor class); add handling for `.modelDownloading` in the `alertTitle` computed property (return `"Downloading model… \(Int(progress * 100))%"`); scan for any exhaustive switch on `translatorState` and add `case .modelDownloading: break` or meaningful UI text where needed.

- [X] T008 [P] [US1] Update `Presentation/Views/LiveTranscriptionView.swift` — in the Spanish pane content area add a `.overlay` or `ZStack` layer that activates when `viewModel.translatorState` matches `.modelDownloading(let progress)`: show a dark-background overlay (`Color.black.opacity(0.75)`) containing a `VStack` with `Text("Downloading recognition model…")` (font: .callout, foreground: .white), `ProgressView(value: progress)` with `.progressViewStyle(.linear).tint(.blue)`, and `Text("\(Int(progress * 100))%")` (font: .caption.monospacedDigit(), foreground: .white.opacity(0.8)). The overlay uses `frame(maxWidth: .infinity, maxHeight: .infinity)` to fill the pane. Do NOT show this as an error alert.

- [X] T009 [US1] Update `App/DependencyContainer.swift` — after wiring the WhisperKit path, add a private method `private func bindDownloadProgress(to viewModel: TranscriptionViewModel)` that runs `Task { [weak self] in guard let manager = self?.whisperModelManager else { return }; for await progress in manager.downloadProgress { await viewModel.updateDownloadProgress(progress) } }`; call this method at the end of `init()` only when `usesWhisper == true`. This keeps the binding alive for the session and bridges the download progress stream to the ViewModel without polling.

**Checkpoint**: Press Record on first launch → progress bar appears in Spanish pane → fills to 100% → transcription text appears. All previously translated text (if any) is untouched.

---

## Phase 4: User Story 2 — Any English Accent Transcription (Priority: P1)

**Goal**: WhisperKit transcribes speakers of any English regional accent with <10% WER on 2-minute conversational speech.

**Independent Test**: A speaker with British, Indian, or Spanish-accented English records a 2-minute monologue. The English pane shows correctly transcribed text. Fewer than 1-in-10 words are wrong or missing. Text is sent to the translation engine within 3 s of each sentence-end pause.

### Implementation

- [X] T010 [US2] Configure `DecodingOptions` in `Data/WhisperSpeechListener.swift` — inside `start()`, before creating `AudioStreamTranscriber`, build `var options = DecodingOptions()` with: `options.task = .transcribe`, `options.language = "en"`, `options.usePrefillPrompt = true`, `options.wordTimestamps = true`, `options.skipSpecialTokens = true`, `options.noSpeechThreshold = 0.6`, `options.temperature = [0.0]` (greedy), `options.chunkingStrategy = .vad`; pass `options` to the `AudioStreamTranscriber` initializer (check current WhisperKit API for the exact parameter name — may be `decodingOptions:` or `options:`).

- [X] T011 [US2] Configure `AudioStreamTranscriber` in `Data/WhisperSpeechListener.swift` — set `silenceThreshold: 0.3` and `requiredSegmentsForConfirmation: 2` in the transcriber's configuration (check current WhisperKit API; these may be `AudioStreamTranscriberConfig` fields or direct init params); these values prevent over-eager confirmation and filter low-energy frames before inference.

- [X] T012 [US2] Validate segment confidence mapping in `Data/WhisperSpeechListener.swift` — implement `private func confidenceFrom(_ segment: TranscriptionSegment) -> Float` as `max(0.0, min(1.0, exp(Float(segment.avgLogProb ?? -1.0))))` (avgLogProb is typically -0.5 to -0.1 for good speech; exp transforms to 0.6–0.9 range); verify in OSLog debug output that confirmed segments log realistic confidence values, not 0.0 or 1.0 always.

**Checkpoint**: Launch with model cached. Press Record. Speak with a non-American accent. Text appears in English pane within 3 s of sentence end. Translation appears in Spanish pane.

---

## Phase 5: User Story 3 — Long Sessions Without Freezing (Priority: P2)

**Goal**: The app records continuously for 15+ minutes with no silent freezes. Any internal engine reset is invisible to the user — no lost text, no error message.

**Independent Test**: Run the app for 15 minutes of continuous speech. Count gaps where no new text appears despite speaking. No gap should exceed 5 seconds (excluding actual silence).

### Implementation

- [X] T013 [US3] Verify watchdog implementation in `Data/WhisperSpeechListener.swift` — confirm `scheduleWatchdog()` is called at the END of `start()` (after transcriber starts), and that every new segment received from the transcriber's callback calls `scheduleWatchdog()` to reset the 30 s timer; if the callback fires for both confirmed AND unconfirmed segments, reset on both. The watchdog must be cancelled in `stop()` and in the `catch` branch of `start()` to avoid a stale watchdog firing after stop.

- [X] T014 [US3] Implement `restartAudioPipeline()` in `Data/WhisperSpeechListener.swift` (or `WhisperSpeechListener+Audio.swift` if split) — the method must: (1) log a `.warning` "Watchdog triggered — restarting audio pipeline"; (2) call `transcriber?.stopStreamTranscription()` (or equivalent stop method — check current API); (3) call `audioEngine?.stop()` then `audioEngine?.inputNode.removeTap(onBus: 0)`; (4) await `Task.sleep(nanoseconds: 200_000_000)` for hardware settle; (5) call `setupAudioEngine()` to reinstall the tap; (6) call `try await transcriber?.startStreamTranscription()` to resume; (7) call `scheduleWatchdog()` to reset the timer; wrap steps 5–6 in `do/catch` — on failure log `.error` and call `continuation?.finish()` only as last resort.

- [X] T015 [US3] Ensure `continuation.finish()` is NEVER called during `restartAudioPipeline()` — only `stop()` and unrecoverable `catch` may finish the stream. Review all code paths in `WhisperSpeechListener.swift` and confirm this invariant holds. Add an `isFinished: Bool` flag if needed to guard against double-finish.

**Checkpoint**: Leave the app recording for 10+ minutes. The English pane continues updating. No error banner appears. Pressing the Restart button (existing feature) preserves all text.

---

## Phase 6: User Story 4 — Subsequent Launches: Instant Start (Priority: P2)

**Goal**: With the model already downloaded, the user can press Record within 5 seconds of launch and transcription begins. No download indicator appears. The model is never re-downloaded.

**Independent Test**: With model cached (launch once from fresh install, let it download). Close the app. Reopen. Press Record within 5 s. Text appears. No download progress overlay appears.

### Implementation

- [X] T016 [US4] Verify cached `WhisperKit` instance in `Data/WhisperModelManager.swift` — confirm that after the first successful `loadModel()` call, `loadedKit` is non-nil and subsequent `loadModel()` calls return immediately from `if let kit = loadedKit { return kit }` without re-downloading or re-initialising. The `loadTask` deduplication (`if let task = loadTask { return try await task.value }`) must also hold for concurrent calls during the same launch.

- [X] T017 [US4] Verify model cache detection in `Data/WhisperModelManager.swift` — before calling `WhisperKit.download(...)`, check whether the model is already cached: use `WhisperKit.fetchAvailableModels()` or probe `FileManager.default.fileExists(atPath:)` at the cache path `~/Documents/huggingface/models--argmaxinc--whisperkit-coreml/`. If cached, skip the download step (call `WhisperKit(config)` directly without `download`). This ensures the downloadProgress stream emits nothing and no progress overlay appears on second launch.

- [X] T018 [US4] Guard download progress binding in `App/DependencyContainer.swift` — the `bindDownloadProgress` task should skip yielding to the viewModel when `progress >= 1.0` or when the model is already cached (i.e., the stream never emits); add `if progress < 1.0 { await viewModel.updateDownloadProgress(progress) }` check, and after the `for await` loop completes ensure `viewModel.translatorState` is reset to `.idle` if it was `.modelDownloading`: `await viewModel.updateDownloadProgress(1.0)` then `await MainActor.run { viewModel.translatorState = .idle }`.

**Checkpoint**: Second launch → no progress bar → press Record within 5 s → text appears.

---

## Phase 7: Polish & Cross-Cutting Concerns

**Purpose**: Logging completeness, file-size compliance, CLAUDE.md accuracy.

- [X] T019 [P] Audit OSLog usage in all new files — every new actor/file must log: (1) `logger.info` at session start/stop; (2) `logger.debug` for each SpeechSegment emitted (text prefix + isFinal); (3) `logger.warning` for watchdog triggers and restarts; (4) `logger.error` for thrown errors. Subsystem: `"com.spanesso.TraslatorApp"`, category: `"WhisperASR"`. Verify no `print()` calls exist.

- [X] T020 [P] Update `CLAUDE.md` — in the **Known Limitations** section, remove "First-time model download is not handled gracefully beyond an error banner; user must open System Settings manually." since this is now resolved by US1. Update **TranslatorState** section to include `.modelDownloading(progress: Double)` case. Update **Data Layer** bullet to mention `WhisperSpeechListener` and `WhisperModelManager`.

- [X] T021 Check line count of `Data/WhisperSpeechListener.swift` — if it exceeds 250 lines, move the `AVAudioEngine` configuration and tap-installation logic into `Data/WhisperSpeechListener+Audio.swift` as an `extension WhisperSpeechListener`. The extension can be `nonisolated` for setup functions that don't touch actor state, or remain actor-isolated.

- [X] T022 Build verification — run `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' build 2>&1 | grep -E 'error:|warning:' | head -40` and resolve any Swift 6 concurrency warnings (never use `@unchecked Sendable` as a shortcut — fix the root cause). Confirm zero build errors and zero concurrency warnings.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Setup (Phase 1)**: No dependencies — start immediately
- **Foundational (Phase 2)**: Depends on Phase 1 completion + user adds WhisperKit SPM package
- **US1 (Phase 3)**: Depends on Phase 2 (needs DependencyContainer wired + WhisperModelManager alive)
- **US2 (Phase 4)**: Depends on Phase 2 (needs WhisperSpeechListener created); independent of US1
- **US3 (Phase 5)**: Depends on T004 (WhisperSpeechListener created in Phase 2); independent of US1/US2
- **US4 (Phase 6)**: Depends on T003 (WhisperModelManager created in Phase 2); independent of US1–US3
- **Polish (Phase 7)**: Depends on all user story phases complete

### User Story Dependencies

- **US1 (P1)**: Requires Phase 2 complete. No dependency on US2/US3/US4.
- **US2 (P1)**: Requires Phase 2 complete. No dependency on US1/US3/US4.
- **US3 (P2)**: Requires T004 (WhisperSpeechListener skeleton). No dependency on US1/US2/US4.
- **US4 (P2)**: Requires T003 (WhisperModelManager). No dependency on US1/US2/US3.

### Parallel Opportunities Within Phase 2

```
T003 (WhisperModelManager)          ──────────────────────────────────►
T004 (WhisperSpeechListener)   starts after T003's interface defined ─►
T005 (WhisperSpeechRepository) parallel with T004 (same interface)  ──►
T006 (DependencyContainer)          depends on T003 + T004 + T005   ──►
```

### Parallel Opportunities Within US1 (Phase 3)

```
T007 (ViewModel updateDownloadProgress)   ──────────►
T008 (LiveTranscriptionView overlay)      ──────────►  (different files, parallel)
T009 (DependencyContainer binding)        depends on T007, T008
```

---

## Parallel Example: Phase 2 Foundational

After T003 defines `WhisperModelManager`'s `actor` interface, T004 and T005 can proceed in parallel:

```
Task A: "Create WhisperSpeechListener.swift actor with start()/stop() interface,
         AVAudioEngine tap, AudioStreamTranscriber callback, SpeechSegment mapping"

Task B: "Create WhisperSpeechRepository.swift that wraps WhisperSpeechListener
         and conforms to SpeechRepositoryProtocol"
```

Both are different files with no shared mutable state → safe to write simultaneously.

---

## Implementation Strategy

### MVP First (US1 + US2 — model downloads and transcription works)

1. Complete Phase 1 (T001–T002) — 5 minutes
2. User adds WhisperKit SPM package in Xcode
3. Complete Phase 2 (T003–T006) — core Data layer
4. Complete Phase 3/US1 (T007–T009) — download progress UI
5. Complete Phase 4/US2 (T010–T012) — accent robustness tuning
6. **STOP and VALIDATE**: First-launch download works, any accent transcribes, pipeline runs end-to-end
7. Complete Phase 5/US3 (T013–T015) — long-session stability
8. Complete Phase 6/US4 (T016–T018) — caching verification
9. Complete Phase 7 (T019–T022) — polish

### Fallback Verification

After Phase 2, temporarily set `usesWhisper = false` in `DependencyContainer` and verify the SFSpeechRecognizer path still works. Then set it back to `true` (or the runtime Apple Silicon detection). This confirms the Intel fallback compiles and runs.

---

## Notes

- T001 is a one-character change — commit separately to keep the locale fix atomic and reviewable.
- T003–T006 are the highest-risk tasks (new external dependency, actor concurrency, hardware detection) — take extra care with Swift 6 isolation.
- WhisperKit's `AudioStreamTranscriber` API may differ slightly from the research findings — always check the installed package source at `DerivedData/.../checkouts/argmax-oss-swift/Sources/WhisperKit/Core/AudioStreamTranscriber.swift` before coding against it.
- The `downloadProgress` `AsyncStream` must use `.bufferingNewest(1)` policy so a slow consumer (ViewModel) never blocks the download progress callback.
- Do NOT call `continuation.finish()` during watchdog restart — this is the most critical invariant of the entire implementation.
