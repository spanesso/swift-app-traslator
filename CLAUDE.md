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
- **`WhisperModelManager`** (Swift `actor`, Apple Silicon only) — downloads and caches the WhisperKit CoreML model (`large-v3-turbo`). Exposes `nonisolated let downloadProgress: AsyncStream<Double>` for first-launch UI feedback. Returns a cached `WhisperKit` instance on subsequent calls. Detects Intel Mac via `sysctlbyname("hw.optional.arm64")` and throws `.unsupportedHardware` if needed.
- **`WhisperSpeechListener`** (Swift `actor`, Apple Silicon only) — wraps `AudioStreamTranscriber`. Converts `confirmedSegments` → `SpeechSegment(isFinal: true)` and `unconfirmedSegments` → `SpeechSegment(isFinal: false)`. Has a 30-second watchdog that restarts the audio pipeline silently if no segment arrives, without calling `continuation.finish()`.
- **`WhisperSpeechRepository`** — thin adapter conforming to `SpeechRepositoryProtocol`; delegates to `WhisperSpeechListener`.
- **`ContinuousSpeechListener`** (Swift `actor`, Intel Mac fallback) — wraps `SFSpeechRecognizer` (locale `"en"`) and `AVAudioEngine`. Used automatically on Intel Macs. Has its own 65-second watchdog and full-engine-stop restart pattern.
- **`SpeechRepository`** — thin adapter for `ContinuousSpeechListener` (Intel fallback path).

### Domain Layer
- **`SpeechSegment`** — value type carrying `text`, `isFinal`, and `confidence`.
- **`TranscribeAudioUseCase`** — orchestrates the pipeline. The primary entry point is `executeBoth()`, which starts transcription and uses a stored detached pump `Task` to fan-out one source `AsyncStream<SpeechSegment>` into two independent streams (raw + segmenter input). `AsyncStream` is single-consumer — using it with two concurrent `for await` loops distributes elements unpredictably. The pump Task reference is stored for explicit cancellation in `stop()`.
- **`NLPSegmenterService`** (`actor`) — differential segmentation using a 3-tier cascade: (1) NLTokenizer detects complete sentences and emits all but the last; (2) tails longer than 15 words are cut at the last clause marker (punctuation or discourse connector); (3) a silence-triggered stability timer (0.7 s normal / 1.2 s low-quality) fires when ASR stabilizes without a terminator. Emits only new deltas (≥ 2 words) over already-committed text. `isLowQualitySpeech()` from `QualityMetricsService` adapts the timer duration.
- **`QualityMetricsService`** (`actor`) — tracks ASR quality signals per session: revision rate, stability delay, words-per-second, confidence, fragmentation. `isLowQualitySpeech()` is consumed by `NLPSegmenterService` for adaptive delay tuning.

### Presentation Layer
- **`TranscriptionViewModel`** (`@Observable`, `@MainActor`) — drives two concurrent tasks: one updates `currentBuffer` (live EN uncommitted tail) from the raw stream; the other feeds stable phrases into `translationRequests: AsyncStream<String>` for the Apple Translation framework. `stopRecording()` finishes the translation stream before cancelling the transcription pipeline.
- **`LiveTranscriptionView`** — split-pane SwiftUI view (35 % EN / 60 % ES). Uses `.translationTask` modifier (Apple `Translation` framework, `en-US → es-ES`, offline-capable) to consume `translationRequests`. **`taskID` is rotated before `translationConfig` is assigned** when recording starts — this is required to destroy the stale `.translationTask` subtree from the previous session.
- **`RecordButton`** — standalone record toggle component.

### Dependency wiring
`DependencyContainer` owns all long-lived instances and constructs the full graph in `init()`, including a **cached `TranscriptionViewModel`** returned by `makeTranscriptionViewModel()`. `TranslatorAppApp` holds a single `@State private var container` so the graph lives for the app session. There are no singletons or global state anywhere in the codebase.

## Key Design Decisions

- **`continuation.finish()` before nil:** In `ContinuousSpeechListener.stop()`, `continuation?.finish()` is called before setting `continuation = nil`. Dropping the reference without finishing leaves any `for await` loop consuming the stream suspended indefinitely.
- **Fan-out pump Task:** `executeBoth()` creates a `Task.detached` pump that forwards each segment to two separate `AsyncStream.Continuation` objects. The reference is stored in `pumpTask` and cancelled in `stop()`.
- **Actor isolation for NLPSegmenterService:** Converted from `final class` to `actor` to move segmentation off the MainActor. With `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, a non-annotated class is implicitly `@MainActor` — this would block the UI on every ASR update.
- **taskID rotation ordering:** `taskID = UUID()` MUST be assigned before `translationConfig = .init(...)` in `onChange(of: isRecording)`. SwiftUI must destroy the old `.translationTask` subtree before the new config triggers a new task — otherwise the new task reads a stale (already-finished) stream.
- **Differential emit:** `NLPSegmenterService` tracks committed text and only yields deltas, so the translation layer never sees duplicate context.
- **Full-array dedup in ViewModel:** `appendTranslation` drops a new sentence if it is identical to or fully contained in any existing translated sentence.
- **Logging:** All components use `OSLog` with subsystem `com.spanesso.TraslatorApp` and per-component categories (`Speech`, `UseCase`, `Segmenter`, `Quality`, `ViewModel`, `UI`).

## TranslatorState

```swift
enum TranslatorState: Equatable {
    case idle
    case inFlight                            // translation request in flight
    case error                               // generic ASR/audio error
    case permissionDenied                    // microphone or speech recognition auth denied
    case modelUnavailable                    // Apple Translation model not downloaded
    case modelDownloading(progress: Double)  // WhisperKit first-launch download in progress
}
```

## Known Limitations

- **Language pair is hardcoded** (`en-US → es-ES`); no language picker exists.
- **UI tests** (`TranslatorAppUITests`) are scaffolding only — no real test logic.
- **WhisperKit requires Apple Silicon** — Intel Macs fall back to `ContinuousSpeechListener` (SFSpeechRecognizer, locale `"en"`) automatically; no user action needed.

## Active Technologies
- Swift 6.0, macOS 14+ (Sonoma), `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- SwiftUI · AVFoundation · NaturalLanguage (NLTokenizer) · Translation (Apple on-device) · SwiftData · OSLog
- Speech (SFSpeechRecognizer) — legacy fallback path (Intel Mac / non-Apple-Silicon)
- WhisperKit (argmaxinc/argmax-oss-swift) — primary ASR backend, Apple Silicon only (004-whisperkit-asr)
- SwiftData (macOS 14+) — in-memory + on-disk via `ModelContainer`

## Recent Changes
- 004-whisperkit-asr: Added WhisperKit (argmaxinc/argmax-oss-swift) as primary ASR backend. `WhisperModelManager` actor handles model download/cache; `WhisperSpeechListener` actor provides `AsyncStream<SpeechSegment>` via `AudioStreamTranscriber`. Added `TranslatorState.modelDownloading(progress:)`. Intel Mac falls back to `ContinuousSpeechListener` (SFSpeechRecognizer, locale `"en"`).
- 003-fix-save-export: SwiftData persistence, conversation save/export, dark card ConversationHistoryView, AirDrop export in ConversationDetailView, restart-listening button.
