# Implementation Prompt: WhisperKit Integration + English Locale Fix

## Overview

You are implementing two improvements to a macOS SwiftUI speech-to-text + translation app:

1. **Locale fix** (trivial): change `"en-US"` → `"en"` in `ContinuousSpeechListener` to better handle non-American English accents.
2. **WhisperKit integration** (substantial): replace `SFSpeechRecognizer` with WhisperKit running on-device via CoreML, which handles any English accent robustly regardless of regional origin.

---

## Project Structure

```
TranslatorApp/
├── App/
│   ├── DependencyContainer.swift   ← wires the full object graph
│   └── TranslatorAppApp.swift
├── Data/
│   ├── ContinuousSpeechListener.swift   ← current ASR backend (SFSpeechRecognizer)
│   ├── Respository/
│   │   ├── SpeechRepository.swift
│   │   └── ConversationRepository.swift
│   └── Models/
│       └── ConversationRecord.swift
├── Domain/
│   ├── Entities/
│   │   ├── SpeechSegment.swift
│   │   ├── ConversationEntity.swift
│   │   └── TranslatorState.swift
│   ├── Interfaces/
│   │   ├── SpeechRepositoryProtocol.swift
│   │   ├── NLPSegmenterServiceProtocol.swift
│   │   └── ConversationRepositoryProtocol.swift
│   ├── Services/
│   │   ├── NLPSegmenterService.swift
│   │   └── QualityMetricsService.swift
│   └── UseCases/
│       ├── TranscribeAudioUseCase.swift
│       ├── SaveConversationUseCase.swift
│       └── FetchConversationsUseCase.swift
└── Presentation/
    ├── ViewModels/
    │   ├── TranscriptionViewModel.swift
    │   └── ConversationHistoryViewModel.swift
    └── Views/
        ├── LiveTranscriptionView.swift
        ├── LiveTranscriptionPanes.swift
        ├── ConversationHistoryView.swift
        ├── ConversationDetailView.swift
        ├── RecordButton.swift
        └── ConversationExport.swift
```

---

## Architecture Rules (Non-Negotiable)

- **Clean Architecture**: `Data → Domain ← Presentation`. `App` is the only layer that knows all three.
- **Domain is pure**: `Domain/` imports only `Foundation`, `NaturalLanguage`, `OSLog`. No `AVFoundation`, no `Speech`, no `WhisperKit`, no `SwiftUI`, no `SwiftData`.
- **Data layer** can import anything (AVFoundation, Speech, WhisperKit).
- **`@Observable` ViewModels** are owned exclusively by `DependencyContainer`. Never `@StateObject` inside a View.
- **Swift 6 strict concurrency**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`. Every actor, class, and closure must satisfy strict Sendable and isolation requirements. No `@unchecked Sendable` as a shortcut — fix the root cause.
- **Max 250 lines per Swift file**. If a file would exceed 250 lines, split it into focused extensions or separate files.
- **No global state, no singletons** outside of `DependencyContainer`.
- **No commits**. User handles all git manually.
- **No creating git branches** without asking.
- **OSLog** for all logging. Subsystem: `com.spanesso.TraslatorApp`. Use per-component categories.
- **macOS 14+** deployment target.

---

## Current Code (Read Before Implementing)

### `SpeechSegment.swift` (Domain — DO NOT MODIFY)
```swift
struct SpeechSegment: Sendable {
    let text: String
    let isFinal: Bool
    let confidence: Float

    nonisolated init(text: String, isFinal: Bool, confidence: Float = 1.0) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}
```

### `SpeechRepositoryProtocol.swift` (Domain — DO NOT MODIFY)
```swift
protocol SpeechRepositoryProtocol {
    func startTranscription() async throws -> AsyncStream<SpeechSegment>
    func stopTranscription() async
}
```

### `SpeechRepository.swift` (Data)
```swift
import Speech
import AVFoundation
import OSLog

final class SpeechRepository: SpeechRepositoryProtocol {
    private let listener: ContinuousSpeechListener
    init(listener: ContinuousSpeechListener) { self.listener = listener }
    func startTranscription() async throws -> AsyncStream<SpeechSegment> { try await listener.start() }
    func stopTranscription() async { await listener.stop() }
}
```

### `ContinuousSpeechListener.swift` (Data — current, 247 lines)
```swift
// Full content: Swift actor that wraps SFSpeechRecognizer.
// Interface:
//   func start() throws -> AsyncStream<SpeechSegment>
//   func stop()
// Key design: restartRecognition() recycles the full audio engine + recognition layer
// every ~60 s when SFSpeechRecognizer times out. A watchdog timer at 65 s forces a
// restart if the callback never fires. isRestarting guards against concurrent restarts.
// Uses locale: Locale(identifier: "en-US")  ← CHANGE THIS TO "en"
```

### `DependencyContainer.swift` (App, abbreviated)
```swift
final class DependencyContainer {
    private let speechListener: ContinuousSpeechListener
    private let speechRepository: SpeechRepositoryProtocol
    private let nlpSegmenter: NLPSegmenterServiceProtocol
    private let qualityMetrics: QualityMetricsService
    private let transcribeUseCase: TranscribeAudioUseCase
    // + persistence + viewModels

    init() {
        let metrics = QualityMetricsService()
        let listener = ContinuousSpeechListener(qualityMetrics: metrics)
        speechListener = listener
        speechRepository = SpeechRepository(listener: listener)
        let segmenter = NLPSegmenterService(qualityMetrics: metrics)
        nlpSegmenter = segmenter
        transcribeUseCase = TranscribeAudioUseCase(
            repository: speechRepository,
            segmenter: nlpSegmenter,
            qualityMetrics: metrics
        )
        // ...
    }
}
```

### `TranslatorState.swift` (Domain)
```swift
enum TranslatorState {
    case idle
    case inFlight
    case error
    case permissionDenied
    case modelUnavailable
    case modelDownloading(progress: Double)   // ADD THIS CASE
}
```

### `TranscriptionViewModel.swift` (Presentation, abbreviated)
```swift
@MainActor @Observable final class TranscriptionViewModel {
    var translatorState: TranslatorState = .idle
    // ...
    // appendTranslation, toggleRecording, stopRecording, restartListening, etc.
}
```

### `LiveTranscriptionView.swift` (Presentation, abbreviated)
```swift
// Shows a split pane: 35% English / 60% Spanish + 5% controls column.
// The controls column has: history button, RecordButton, restart button, 
// save button, export ShareLink.
// Displays translatorState via alertTitle.
```

---

## Task 1: Locale Fix (5 minutes)

In `ContinuousSpeechListener.swift`, change:
```swift
private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
```
to:
```swift
private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "en"))
```

---

## Task 2: WhisperKit Integration

### 2.0 — SPM Package (User must do this in Xcode)

Tell the user:
> In Xcode → File → Add Package Dependencies → paste: `https://github.com/argmaxinc/WhisperKit`
> Add to target: `TranslatorApp`

### 2.1 — New files to create

#### `TranslatorApp/Data/WhisperSpeechListener.swift`

A Swift `actor` with the same interface as `ContinuousSpeechListener`:
- `func start() throws -> AsyncStream<SpeechSegment>` 
- `func stop()`

Implementation requirements:
- Load the model asynchronously during `start()`. Model: `"large-v3-turbo"`. If the model is not yet downloaded, WhisperKit downloads it automatically (~800 MB).
- During model download, yield a special `SpeechSegment` with `text: "__DOWNLOADING__"` and `isFinal: false` so the ViewModel/UI can detect and display progress. Better: use the progress callback from WhisperKit to report `Double` progress to the caller. See "Model Download Progress" section below.
- After the model loads, capture audio via `AVAudioEngine` with a tap on the input node.
- Use WhisperKit's real-time transcription API (check the current WhisperKit README for the exact streaming/chunked API — it may be `AudioStreamTranscriber`, `StreamingTranscription`, or a manual VAD+chunk approach).
- Emit `SpeechSegment(text:isFinal:confidence:)` through the `AsyncStream` continuation:
  - Partial results → `isFinal: false`
  - Committed segments (end of sentence / silence detected) → `isFinal: true`
- Maintain a watchdog timer: if no segment is emitted in 30 seconds, restart the capture pipeline without closing the `AsyncStream`.
- The `AsyncStream` must stay alive for the full session — never call `continuation.finish()` except in `stop()` or on an unrecoverable error.
- Max 250 lines. Split into `WhisperSpeechListener+Audio.swift` or similar if needed.
- Use `OSLog` category: `"WhisperASR"`.
- Full Swift 6 strict concurrency compliance.

#### `TranslatorApp/Data/WhisperModelManager.swift`

A separate `actor` (or `@MainActor` class) responsible for:
- Tracking model download/load state
- Exposing `func loadModel() async throws -> WhisperKit`
- Caching the loaded `WhisperKit` instance so repeated `start()` calls don't re-download
- Reporting download progress as a `Double` (0.0–1.0) via `AsyncStream<Double>` or a callback

### 2.2 — Modify existing files

#### `TranslatorApp/Domain/Entities/TranslatorState.swift`

Add the new case:
```swift
case modelDownloading(progress: Double)
```
Make sure the existing switch statements in `TranscriptionViewModel` and `LiveTranscriptionView` handle this case (add it to `alertTitle` and any other switches).

#### `TranslatorApp/Data/Respository/SpeechRepository.swift`

Create a new `WhisperSpeechRepository` that wraps `WhisperSpeechListener` and conforms to `SpeechRepositoryProtocol`. Or update `SpeechRepository` to accept a protocol-typed listener. The cleanest approach:

```swift
// New file: WhisperSpeechRepository.swift
final class WhisperSpeechRepository: SpeechRepositoryProtocol {
    private let listener: WhisperSpeechListener
    // ...
}
```

#### `TranslatorApp/App/DependencyContainer.swift`

Wire `WhisperSpeechListener` and `WhisperSpeechRepository` as the new speech backend. Keep `ContinuousSpeechListener` compiled (do not delete it) as a fallback — just don't wire it by default.

Optionally add a `usesWhisper: Bool = true` flag at the top of `DependencyContainer.init()` so a developer can switch backends without changing architecture.

#### `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift`

Handle the `modelDownloading(progress:)` state:
- In the Spanish pane or an overlay, show a progress bar + message: "Downloading Whisper model… X%"
- Do NOT show this as an error alert — it's expected on first launch.
- Once `progress >= 1.0` (model loaded), hide the indicator and normal transcription begins.

#### `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift`

Handle `modelDownloading` in `handleSpeechError` or as a new method. The ViewModel needs to receive progress updates and set `translatorState = .modelDownloading(progress: p)`. Consider adding:
```swift
func updateDownloadProgress(_ progress: Double) {
    translatorState = .modelDownloading(progress: progress)
}
```

### 2.3 — Model Download Progress Flow

The recommended flow:
```
WhisperModelManager.loadModel() {
    reports progress via callback/stream
}
    ↓
WhisperSpeechListener.start() awaits model load
    ↓ (during download)
yields SpeechSegment or triggers progress callback
    ↓
SpeechRepository passes through
    ↓
TranscribeAudioUseCase fan-out pump
    ↓
TranscriptionViewModel.updateDownloadProgress(p)
    ↓ (sets translatorState = .modelDownloading(progress: p))
LiveTranscriptionView shows progress bar
```

The cleanest architecture: `WhisperSpeechListener` exposes a separate `AsyncStream<Double>` for download progress, read by `DependencyContainer` and injected into the ViewModel separately. This avoids polluting `AsyncStream<SpeechSegment>` with download state.

---

## WhisperKit API Reference (as of early 2025)

Check the current WhisperKit README at `https://github.com/argmaxinc/WhisperKit` for the exact API. The following is representative but may have evolved:

```swift
import WhisperKit

// Initialize (downloads model if needed)
let pipe = try await WhisperKit(
    model: "large-v3-turbo",
    verbose: false,
    logLevel: .none
)

// For streaming/real-time, WhisperKit provides AudioStreamTranscriber or
// you can use manual chunking with AVAudioEngine:

// Option A: AudioStreamTranscriber (preferred if available in current version)
let transcriber = AudioStreamTranscriber(
    audioEncoder: pipe.audioEncoder,
    featureExtractor: pipe.featureExtractor,
    segmentSeeker: pipe.segmentSeeker,
    textDecoder: pipe.textDecoder,
    tokenizer: pipe.tokenizer
) { segments in
    // Handle new segments
}
try await transcriber.startStreamTranscription()

// Option B: Manual chunks with VAD
// Capture audio with AVAudioEngine tap at 16kHz
// Accumulate samples in a ring buffer
// When silence detected (via energy threshold) or after N seconds, call:
let results = try await pipe.transcribe(audioArray: samples)
// results[0].text contains the transcription

// Decoding options for best accent robustness:
var options = DecodingOptions()
options.task = .transcribe
options.language = "en"
options.withoutTimestamps = true
options.usePrefillPrompt = true   // improves robustness
```

**Model names**: `"tiny"`, `"base"`, `"small"`, `"medium"`, `"large-v3"`, `"large-v3-turbo"`.
Use `"large-v3-turbo"` for best accuracy/speed tradeoff.

**Audio format**: WhisperKit expects 16kHz mono Float32 samples. Configure `AVAudioEngine` accordingly.

---

## Quality Requirements

- [ ] App compiles without warnings under Swift 6 strict concurrency
- [ ] Changing `usesWhisper = false` in `DependencyContainer` falls back to `SFSpeechRecognizer` with locale `"en"`
- [ ] On first launch, a download progress indicator appears in the Spanish pane (not an error alert)
- [ ] After model loads, transcription begins automatically without user action
- [ ] Model is cached: second launch does not re-download
- [ ] `AsyncStream<SpeechSegment>` interface is preserved — `TranscribeAudioUseCase`, `NLPSegmenterService`, `TranscriptionViewModel` are **not modified** except for new `TranslatorState` case handling
- [ ] No file exceeds 250 lines
- [ ] Domain layer has zero WhisperKit imports
- [ ] Watchdog timer restarts capture if WhisperKit stalls for > 30 s without output
- [ ] `stop()` properly cancels model loading if called during download
- [ ] Logs use OSLog with appropriate levels (info for session events, debug for per-segment, warning for watchdog, error for failures)

---

## Files To Create (summary)

| File | Layer | Action |
|------|-------|--------|
| `Data/WhisperSpeechListener.swift` | Data | CREATE |
| `Data/WhisperModelManager.swift` | Data | CREATE |
| `Data/Respository/WhisperSpeechRepository.swift` | Data | CREATE |
| `Domain/Entities/TranslatorState.swift` | Domain | MODIFY — add `modelDownloading` case |
| `Data/ContinuousSpeechListener.swift` | Data | MODIFY — locale `"en-US"` → `"en"` |
| `App/DependencyContainer.swift` | App | MODIFY — wire WhisperKit backend |
| `Presentation/ViewModels/TranscriptionViewModel.swift` | Presentation | MODIFY — handle `modelDownloading` |
| `Presentation/Views/LiveTranscriptionView.swift` | Presentation | MODIFY — show download progress UI |

## Files NOT to touch

- `SpeechRepositoryProtocol.swift` — interface is already correct
- `SpeechSegment.swift` — entity is already correct
- `TranscribeAudioUseCase.swift` — fan-out pump is engine-agnostic
- `NLPSegmenterService.swift` — operates on text, not audio
- `NLPSegmenterServiceProtocol.swift`
- `ConversationHistoryView.swift`, `ConversationDetailView.swift`, `RecordButton.swift`
- All persistence files

---

## Implementation Order

1. Locale fix in `ContinuousSpeechListener.swift` (1 line)
2. Add `modelDownloading` to `TranslatorState.swift`
3. Create `WhisperModelManager.swift`
4. Create `WhisperSpeechListener.swift`
5. Create `WhisperSpeechRepository.swift`
6. Update `DependencyContainer.swift`
7. Update `TranscriptionViewModel.swift` (handle new state)
8. Update `LiveTranscriptionView.swift` (download progress UI)
9. Build and verify zero warnings

---

## Important Notes

- After all code changes, tell the user to: open Xcode → add the WhisperKit package → add all new `.swift` files to the `TranslatorApp` target (File → Add Files to "TranslatorApp").
- The first transcription session after install will download the model. `large-v3-turbo` is ~800 MB. Subsequent launches load from disk cache (WhisperKit manages this automatically in `~/Library/Caches`).
- Do NOT add any API keys, remote services, or analytics. This must remain a fully offline app.
- Do NOT commit any changes. The user manages all git operations manually.
