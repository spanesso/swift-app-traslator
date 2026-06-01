# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a pure Xcode project — there is no `Makefile`, `Package.swift`, or CLI build script.

- **Open project:** `open TranslatorApp.xcodeproj`
- **Build from CLI:** `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' build`
- **Run tests:** `xcodebuild test -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS'`
- **Run a single UI test:** `xcodebuild test -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' -only-testing:TranslatorAppUITests/TranslatorAppUITests`

The app requires macOS (not iOS/iPadOS) and needs microphone + speech recognition permissions granted at runtime.

## Architecture

The app follows Clean Architecture with three layers wired together by `DependencyContainer`:

```
Data  →  Domain  →  Presentation
```

### Data Layer
- **`ContinuousSpeechListener`** (Swift `actor`) — wraps `SFSpeechRecognizer` and `AVAudioEngine`. Produces an `AsyncStream<SpeechSegment>` of partial and final ASR results. Also records quality metrics on every transcript update.
- **`SpeechRepository`** — thin adapter that conforms to `SpeechRepositoryProtocol`; delegates to `ContinuousSpeechListener`.

### Domain Layer
- **`SpeechSegment`** — value type carrying `text`, `isFinal`, and `confidence`.
<<<<<<< HEAD
- **`TranscribeAudioUseCase`** — orchestrates the pipeline. The primary entry point is `executeBoth()`, which starts transcription and uses a detached pump `Task` to fan-out one source `AsyncStream<SpeechSegment>` into two independent streams (raw + segmenter input), because `AsyncStream` is single-consumer. Also exposes `executeRaw()` and `executeSegmented(from:)` separately.
- **`NLPSegmenterService`** — differential segmentation using a 3-tier cascade: (1) NLTokenizer detects complete sentences and emits all but the last; (2) tails longer than 15 words are cut at the last clause marker (punctuation or discourse connector); (3) a 0.7 s stability timer fires if the ASR text stabilizes without a terminator. Emits only new deltas (≥ 2 words) over the already-committed text. Prevents micro-translations.
=======
- **`TranscribeAudioUseCase`** — orchestrates the two-phase pipeline:
  1. `executeRaw()` → raw `AsyncStream<SpeechSegment>` from the repository.
  2. `executeSegmented(from:)` → pipes the raw stream through `NLPSegmenterService`, returning `AsyncStream<String>` of stable phrase chunks.
- **`NLPSegmenterService`** — differential segmentation: waits 1.4 s for ASR to stabilize, then emits only the new delta if it's ≥ 5 words or ends with a period. Prevents micro-translations.
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
- **`QualityMetricsService`** (`actor`) — tracks ASR quality signals per session: revision rate, stability delay, words-per-second, confidence, fragmentation. Exposes `isLowQualitySpeech()` for adaptive strategies.

### Presentation Layer
- **`TranscriptionViewModel`** (`@Observable`, `@MainActor`) — drives two concurrent tasks: one updates `currentBuffer` from the raw stream (live EN text), the other feeds stable phrases into `translationRequests: AsyncStream<String>` for the Apple Translation framework.
- **`LiveTranscriptionView`** — split-pane SwiftUI view (35 % EN / 60 % ES). Uses `.translationTask` modifier (Apple `Translation` framework, `en-US → es-ES`, offline-capable) to consume `translationRequests` and calls `viewModel.appendTranslation(_:)` with results. Auto-scrolls both panes on text change.
- **`RecordButton`** — standalone record toggle component.

### Dependency wiring
<<<<<<< HEAD
`DependencyContainer` owns all long-lived instances and constructs the full graph in `init()`. `TranslatorAppApp` holds a single `@State private var container` so the graph lives for the app session. There are no singletons or global state anywhere in the codebase.
=======
`DependencyContainer` owns all long-lived instances and constructs the full graph in `init()`. `TranslatorAppApp` holds a single `@State private var container` so the graph lives for the app session.
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2

## Key Design Decisions

- **Differential emit:** `NLPSegmenterService` tracks `lastEmittedFullText` and only yields the *delta* over the last emission, so the translation layer never sees duplicate context.
- **Duplicate-guard in ViewModel:** `appendTranslation` drops a new sentence if it is identical to or fully contained in the last appended sentence.
<<<<<<< HEAD
- **Translation engine lifecycle:** On recording start, `taskID` is first mutated to a new `UUID` (forcing SwiftUI to destroy the previous `.translationTask` subtree), then `translationConfig` is assigned. On stop, `translationConfig` is set to `nil`. This ordering is required — assigning config without rotating the ID leaves a stale task consuming the old stream.
- **Logging:** All components use `OSLog` with subsystem `com.spanesso.TraslatorApp` and per-component categories (`Speech`, `UseCase`, `Segmenter`, `Quality`, `ViewModel`, `UI`).

## Known Gaps / Future Work

- **`isLowQualitySpeech()`** is computed by `QualityMetricsService` but never consumed — exists as infrastructure for adaptive `stabilityDelay` tuning.
- **`CryptoKit`** is imported in `NLPSegmenterService` but unused — likely intended for phrase deduplication via hashing.
- **Language pair is hardcoded** (`en-US → es-ES`) in both `ContinuousSpeechListener` and `LiveTranscriptionView`; no language picker exists.
- **UI tests** (`TranslatorAppUITests`) are scaffolding only — no real test logic.

## Active Technologies
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + SwiftUI, Speech (SFSpeechRecognizer), AVFoundation, NaturalLanguage (NLTokenizer), Translation (Apple on-device), OSLog (001-improve-transcription-translation)
- In-memory only (no persistence required) (001-improve-transcription-translation)

## Recent Changes
- 001-improve-transcription-translation: Added Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + SwiftUI, Speech (SFSpeechRecognizer), AVFoundation, NaturalLanguage (NLTokenizer), Translation (Apple on-device), OSLog
=======
- **Translation engine lifecycle:** `translationConfig` is set to `nil` on stop, which tears down the `.translationTask` session. On next record, a new `UUID` is assigned to `.id(taskID)` to force SwiftUI to recreate the task.
- **Logging:** All components use `OSLog` with subsystem `com.spanesso.TraslatorApp` and per-component categories (`Speech`, `UseCase`, `Segmenter`, `Quality`, `ViewModel`, `UI`).
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
