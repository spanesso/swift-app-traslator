# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a pure Xcode project — there is no `Makefile`, `Package.swift`, or CLI build script.

- **Open project:** `open TranslatorApp.xcodeproj`
- **Build from CLI:** `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
- **Run unit tests:** `xcodebuild test -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TranslatorAppTests`

**Platform: iOS/iPadOS 26.1+** (`IPHONEOS_DEPLOYMENT_TARGET = 26.1`, `TARGETED_DEVICE_FAMILY = "1,2"`). Needs microphone + speech recognition permissions at runtime. Declares the `audio` background mode so capture survives a locked screen (008 decision Q3).

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`: **new `.swift` files under `TranslatorApp/` and `TranslatorAppTests/` are added to their target automatically** — `project.pbxproj` does not need editing.

Behaviour that needs real hardware — interruptions, route changes, background capture — is validated by hand; see `specs/008-fix-audio-pipeline-resilience/quickstart.md`.

## Architecture

The app follows Clean Architecture with three layers wired together by `DependencyContainer`:

```
Data  →  Domain  →  Presentation
```

### Data Layer
- **`ContinuousSpeechListener`** (Swift `actor`) — wraps `SFSpeechRecognizer` and `AVAudioEngine`. Produces an `AsyncStream<SpeechSegment>` of partial and final ASR results. Also records quality metrics on every transcript update. Calls `continuation.finish()` in `stop()` before setting it to `nil` — this is required for downstream `for await` loops to terminate.
- **`AppleSFSpeechEngine`** (`actor`) — the single ASR engine, wrapping `SFSpeechRecognizer` with on-device recognition. Consolidates the three near-duplicate engines that existed before 008 (`ContinuousSpeechListener`, `LegacySFSpeechEngine`, `AppleSpeechAnalyzerEngine`), which had already diverged: only one had a watchdog, only another closed the stream when a restart failed. Split across `+Rotation` (recogniser swap, watchdog) and `+Resilience` (audio-system events).
- **`AudioCaptureSession`** (`actor`) — owns `AVAudioEngine` and the microphone tap. **The tap is installed once per recording session**; recogniser rotation never touches it. Rebuilt only on a route or configuration change, always reading the input format at install time.
- **`RecognitionRequestBox`** — lock-protected, swappable holder for the active recognition request. Readable from the audio render thread without `await`; this is what makes rotation a pointer swap.
- **`AudioSessionCoordinator`** (`actor`) — the single owner of `AVAudioSession` and of every audio notification (interruption, route change, configuration change, media-services reset). Emits `AudioSessionEvent`s upward.
- **`AudioRingBuffer`** (`nonisolated final class`) — preallocated carry-over window. The render thread only does `memcpy`; nothing is allocated there.
- **`PipelineTelemetry`** — structured OSLog telemetry, category `Telemetry`.
- **`SpeechRepository`** — thin adapter conforming to `SpeechRepositoryProtocol`; applies `EmptySegmentFilter` once for every engine and records quality signals.

### Domain Layer
- **`SpeechSegment`** — value type carrying `text`, `isFinal`, `confidence`, `tokens`, and `sessionGeneration` (which recognition session produced it).
- **`ConversationFragment`** — the paired unit of a conversation: source text plus a `TranslationOutcome` (`pending` / `translated` / `unavailable(reason)`). In memory only.
- **`RecordingSessionState`** — `idle` / `active` / `suspended(reason)` / `stopping`. `suspended → idle` is illegal by construction.
- **`LiveTailReconciler`** — pure, unit-tested computation of the live English tail against the CURRENT recognition session's baseline.
- **`ConversationTextFormatter`** — the only producer of conversation text; guarantees both language blocks have the same line count.
- **`TranscribeAudioUseCase`** — orchestrates the pipeline. The primary entry point is `executeBoth()`, which starts transcription and uses a stored detached pump `Task` to fan-out one source `AsyncStream<SpeechSegment>` into two independent streams (raw + segmenter input). `AsyncStream` is single-consumer — using it with two concurrent `for await` loops distributes elements unpredictably. The pump Task reference is stored for explicit cancellation in `stop()`.
- **`NLPSegmenterService`** (`actor`) — differential segmentation using a 3-tier cascade: (1) NLTokenizer detects complete sentences and emits all but the last; (2) tails longer than 15 words are cut at the last clause marker (punctuation or discourse connector); (3) a silence-triggered stability timer (0.7 s normal / 1.2 s low-quality) fires when ASR stabilizes without a terminator. Emits only new deltas (≥ 2 words) over already-committed text. `isLowQualitySpeech()` from `QualityMetricsService` adapts the timer duration.
- **`QualityMetricsService`** (`actor`) — tracks ASR quality signals per session: revision rate, stability delay, words-per-second, confidence, fragmentation. `isLowQualitySpeech()` is consumed by `NLPSegmenterService` for adaptive delay tuning.

### Presentation Layer
- **`TranscriptionViewModel`** (`@Observable`, `@MainActor`) — owns `fragments: [ConversationFragment]` and `sessionState`. Split across `+Session` (lifecycle, suspension, raw-stream handling) and `+Fragments` (commit, translation resolution, drain, save/export). `stopRecording()` drains in-flight translations for up to 3 s before closing.
- **`LiveTranscriptionView`** — split-pane SwiftUI view (35 % EN / 60 % ES). Uses `.translationTask` modifier (Apple `Translation` framework, `en-US → es-ES`, offline-capable) to consume `translationRequests`. **`taskID` is rotated before `translationConfig` is assigned** when recording starts — this is required to destroy the stale `.translationTask` subtree from the previous session.
- **`RecordButton`** — standalone record toggle component.

### Dependency wiring
`DependencyContainer` owns all long-lived instances and constructs the full graph in `init()`, including a **cached `TranscriptionViewModel`** returned by `makeTranscriptionViewModel()`. `TranslatorAppApp` holds a single `@State private var container` so the graph lives for the app session. There are no singletons or global state anywhere in the codebase.

## Key Design Decisions

- **The tap is permanent (008):** recogniser rotation swaps the request inside `RecognitionRequestBox`; it never calls `removeTap`/`installTap`. Before 008 the tap was rebuilt on every rotation, and between the two calls nothing was capturing — not the request, not the carry-over buffer. Expected `blindMs` in the `TAP_SWAP` telemetry is **0**, not "small". Never reintroduce a tap teardown on the rotation path.
- **On-device recognition (008):** `requiresOnDeviceRecognition = true` when supported. It removes the ~1-minute server audio limit that forced constant rotation, and the whole class of network errors that were invisible because the error code was never read.
- **An interruption suspends, it does not stop (008):** `RecordingSessionState.suspended` keeps the stream open, the history intact and the audio session ACTIVE. `setActive(false)` must never be called while suspended — that is what allows resuming. Recovery uses the end-of-interruption notification **plus a 2 s reactivation poll**, because iOS does not reliably deliver that notification; a successful `setActive(true)` is the real proof the interruption ended. This is what recovers an alarm or a call the user never touched.
- **Never report an audio interruption as a permissions problem (008):** it was, and the message was false. `TranslatorState.suspendedByAudioInterruption` and a banner replace that alert.
- **Reschedule the stability timer on every early return (008):** `NLPSegmenterService` cancels it before several `continue` paths. All of them go through `reschedule(...)`. The critical one is the duplicate-partial path: the recogniser re-emits the same text while the speaker pauses, and each repeat used to kill the pending emission — the phrase was then never translated. The `STAB_CANCEL` telemetry carries `rescheduled`; a `false` with a non-empty tail means the bug is back.
- **Reconcile against the recognition session, not the meeting (008):** `LiveTailReconciler`'s baseline resets on every rotation, signalled by `SpeechSegment.sessionGeneration`. Comparing incoming text against the whole meeting's committed text froze the English pane permanently about a minute in, because a ~60 s recognition session can never out-count the whole meeting.
- **A fragment never disappears (008):** a failed, empty, too-short or timed-out translation becomes `.unavailable(reason)` and still occupies its line. Both exported blocks use the same separator and always have the same line count; `SaveConversationUseCase` refuses to persist misaligned blocks. Absence must be a visible marker, never a missing row.
- **Unbounded in-session history (007, preserved in 008):** `fragments` is append-only for the whole recording session. It is cleared only when a NEW (non-continuing) session starts. Never reintroduce a `removeFirst()` trim — that silently discarded the start of the conversation.
- **Fan-out pump Task:** `executeBoth()` creates a `Task.detached` pump that forwards each segment to two separate `AsyncStream.Continuation` objects, cancelled in `stop()`.
- **Actor isolation and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:** every type that is touched from the audio render thread or from an actor needs explicit `nonisolated` — including static members and whole classes (`nonisolated final class AudioRingBuffer`). Without it the compiler warns and the isolation is genuinely wrong, not merely noisy. Static stored properties whose initializer is not a compile-time literal become MainActor-isolated; prefer `nonisolated static var x: T { ... }`.
- **taskID rotation ordering:** `taskID = UUID()` MUST be assigned before `translationConfig = .init(...)` in `onChange(of: isRecording)`, so SwiftUI destroys the old `.translationTask` subtree before the new config starts a task.
- **Logging:** All components use `OSLog` with subsystem `com.spanesso.TraslatorApp` and per-component categories (`AppleSFSpeech`, `AudioCapture`, `AudioSession`, `SpeechRepo`, `UseCase`, `Segmenter`, `Quality`, `ViewModel`, `UI`, `Container`, `Coordinator`).
- **Telemetry (008):** category `Telemetry`, one line per event as `[KIND] sid=A1B2 key=value …`. Prefixes are a published interface — renaming one breaks every saved log filter. Telemetry carries counts, durations and error codes, **never transcribed text**, and never blocks or throws.

  ```
  [SESSION_END] sid=A1B2 reason=error errDomain=kAFAssistantErrorDomain errCode=203 durMs=61240 restartIdx=7
  grep '\[TAP_SWAP\]'    | grep -v 'blindMs=0'      # must be EMPTY
  grep '\[STAB_CANCEL\]' | grep 'rescheduled=false' # must be EMPTY
  ```

## TranslatorState

```swift
enum TranslatorState {
    case idle
    case inFlight           // translation request in flight
    case error              // generic ASR/audio error
    case permissionDenied   // microphone or speech recognition auth denied
    case modelUnavailable   // Apple Translation model not downloaded
    case downloadingModel
    case downloadingASRModel(progress: Double)
    case correcting
    case suspendedByAudioInterruption(AudioInterruptionReason)  // 008: recoverable pause
}
```

## Known Limitations

- **Language pair is hardcoded** (`en-US → es-ES`); no language picker exists.
- **UI tests** (`TranslatorAppUITests`) are scaffolding only. Real unit tests live in `TranslatorAppTests` (35 cases covering the reconciler, the formatter, session-state transitions and segmenter timing).
- **The WhisperKit engine is withdrawn** (008 decision Q1). `EnginePreference.whisperPreferred` is retained as a stored value but resolves to the Apple route; `isAvailable` returns false and the UI shows it as unavailable. `WhisperKitEngine.swift` stays in the repo, unreferenced, pending a redesign (sliding window with overlap, stable-segment emission).
- **`SpeechAnalyzer` is not used.** With a 26.1 deployment target it is available on every supported device and would remove session rotation entirely — making US6 and part of US2 unnecessary. Deliberately deferred; see `specs/008-fix-audio-pipeline-resilience/research.md` §R6.
- **First-time translation model download** is surfaced as an error banner; the user must open Settings manually.

## Active Technologies
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + SwiftUI · Speech (SFSpeechRecognizer) · AVFoundation · NaturalLanguage · Translation (Apple on-device) · SwiftData · OSLog (003-fix-save-export)
- SwiftData (macOS 14+) — in-memory + on-disk via `ModelContainer` (003-fix-save-export)
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency) (005-accent-robust-asr)
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency) + SwiftUI · Speech (`SFSpeechRecognizer`; iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` in Phase 3) · AVFoundation (`AVAudioEngine`, `AVAudioConverter`) · NaturalLanguage (`NLTokenizer`/`NLTagger`) · Translation (Apple on-device) · WhisperKit (SPM, already present) · BackgroundAssets · OSLog · SwiftData (006-fix-asr-word-loss)
- SwiftData (`ConversationRecord`, `SessionQualityRecord`); WhisperKit model files on disk in App Support. No new file types. (006-fix-asr-word-loss)
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency) + SwiftUI, Speech (`SFSpeechRecognizer`), AVFoundation, NaturalLanguage, Translation (Apple on-device), SwiftData, OSLog (007-preserve-conversation-history)
- In-memory per live session (`TranscriptionViewModel` arrays). Persistence of a finished session is existing SwiftData Save/Export — unchanged. (007-preserve-conversation-history)
- Swift 5.0 con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (concurrencia estricta) + SwiftUI · Speech (`SFSpeechRecognizer`) · AVFoundation (`AVAudioEngine`, `AVAudioSession`) · NaturalLanguage (`NLTokenizer`, `NLTagger`) · Translation (Apple, en dispositivo) · SwiftData · OSLog. **Sin dependencias nuevas.** WhisperKit permanece como paquete SPM pero queda sin referenciar por el selector de motor. (008-fix-audio-pipeline-resilience)
- SwiftData (`ConversationRecord`, `SessionQualityRecord`). **Sin migración de esquema** (decisión Q2). (008-fix-audio-pipeline-resilience)

- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- SwiftUI, Speech (SFSpeechRecognizer), AVFoundation, NaturalLanguage (NLTokenizer), Translation (Apple on-device), OSLog
- In-memory only (no persistence)

## Recent Changes
- 003-fix-save-export: Added Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + SwiftUI · Speech (SFSpeechRecognizer) · AVFoundation · NaturalLanguage · Translation (Apple on-device) · SwiftData · OSLog
