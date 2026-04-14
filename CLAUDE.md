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
- **`TranscribeAudioUseCase`** — orchestrates the two-phase pipeline:
  1. `executeRaw()` → raw `AsyncStream<SpeechSegment>` from the repository.
  2. `executeSegmented(from:)` → pipes the raw stream through `NLPSegmenterService`, returning `AsyncStream<String>` of stable phrase chunks.
- **`NLPSegmenterService`** — differential segmentation: waits 1.4 s for ASR to stabilize, then emits only the new delta if it's ≥ 5 words or ends with a period. Prevents micro-translations.
- **`QualityMetricsService`** (`actor`) — tracks ASR quality signals per session: revision rate, stability delay, words-per-second, confidence, fragmentation. Exposes `isLowQualitySpeech()` for adaptive strategies.

### Presentation Layer
- **`TranscriptionViewModel`** (`@Observable`, `@MainActor`) — drives two concurrent tasks: one updates `currentBuffer` from the raw stream (live EN text), the other feeds stable phrases into `translationRequests: AsyncStream<String>` for the Apple Translation framework.
- **`LiveTranscriptionView`** — split-pane SwiftUI view (35 % EN / 60 % ES). Uses `.translationTask` modifier (Apple `Translation` framework, `en-US → es-ES`, offline-capable) to consume `translationRequests` and calls `viewModel.appendTranslation(_:)` with results. Auto-scrolls both panes on text change.
- **`RecordButton`** — standalone record toggle component.

### Dependency wiring
`DependencyContainer` owns all long-lived instances and constructs the full graph in `init()`. `TranslatorAppApp` holds a single `@State private var container` so the graph lives for the app session.

## Key Design Decisions

- **Differential emit:** `NLPSegmenterService` tracks `lastEmittedFullText` and only yields the *delta* over the last emission, so the translation layer never sees duplicate context.
- **Duplicate-guard in ViewModel:** `appendTranslation` drops a new sentence if it is identical to or fully contained in the last appended sentence.
- **Translation engine lifecycle:** `translationConfig` is set to `nil` on stop, which tears down the `.translationTask` session. On next record, a new `UUID` is assigned to `.id(taskID)` to force SwiftUI to recreate the task.
- **Logging:** All components use `OSLog` with subsystem `com.spanesso.TraslatorApp` and per-component categories (`Speech`, `UseCase`, `Segmenter`, `Quality`, `ViewModel`, `UI`).
