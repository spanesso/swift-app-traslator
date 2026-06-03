# Data Model: WhisperKit ASR Integration

**Feature**: 004-whisperkit-asr  
**Phase**: 1 — Design  
**Date**: 2026-06-02

---

## Entities

### 1. RecognitionModel

The downloadable CoreML Whisper model stored in local app cache.

| Field | Type | Description |
|-------|------|-------------|
| `variant` | `String` | Model identifier (e.g., `"openai_whisper-large-v3-v20240930_turbo_632MB"`) |
| `state` | `ModelState` | Current lifecycle state (see below) |
| `cacheURL` | `URL?` | Local path once downloaded; `nil` if not yet downloaded |

**State machine**:

```
notDownloaded ──► downloading(progress: Double) ──► downloaded
                                                         │
                                                         ▼
                                                      loading
                                                         │
                                                         ▼
                                                       active
```

- `notDownloaded`: No local copy exists.
- `downloading(progress: Double)`: Download in progress; `progress` is `0.0–1.0`.
- `downloaded`: Local copy exists; `WhisperKit` instance not yet created.
- `loading`: `WhisperKit` initializer is running (model being loaded into memory/ANE).
- `active`: `WhisperKit` instance ready; transcription may begin.

**Validation rules**:
- `progress` must be `0.0 ≤ progress ≤ 1.0`.
- Transition from `active` → `notDownloaded` is only valid if the cache directory is explicitly cleared (not a normal flow).

---

### 2. DownloadProgress

Real-time progress scalar reported during initial model fetch.

| Field | Type | Description |
|-------|------|-------------|
| `fraction` | `Double` | Completion ratio `0.0–1.0` |
| `bytesReceived` | `Int64` | Bytes downloaded so far |
| `bytesExpected` | `Int64?` | Total expected bytes; `nil` if server does not provide `Content-Length` |

**Derived properties**:
- `percentage: Int` — `Int(fraction * 100)`
- `isComplete: Bool` — `fraction >= 1.0`

---

### 3. SpeechSegment *(existing — no changes)*

Utterance chunk emitted by the recognition engine.

| Field | Type | Description |
|-------|------|-------------|
| `text` | `String` | Transcribed text content |
| `isFinal` | `Bool` | `true` for committed segments, `false` for partial (live) results |
| `confidence` | `Float` | ASR confidence score `0.0–1.0` |

Mapping from WhisperKit:
- `confirmedSegments` → `isFinal: true`
- `unconfirmedSegments` → `isFinal: false`
- Confidence: `segment.avgLogProb` transformed via `exp(avgLogProb)` clamped to `0.0–1.0`

---

### 4. TranslatorState *(extended — one new case)*

Lifecycle state of the recognition + translation pipeline (Domain enum).

```swift
enum TranslatorState {
    case idle
    case inFlight                            // translation request in flight
    case error                               // generic ASR/audio error
    case permissionDenied                    // microphone/speech auth denied
    case modelUnavailable                    // Apple Translation model not ready
    case modelDownloading(progress: Double)  // NEW: WhisperKit download in progress
}
```

**Validation**: `modelDownloading` should only be active when the app is in a `notDownloaded → downloading` transition. Once `progress >= 1.0`, state transitions to `idle` (ready to record).

---

## State Transitions (RecognitionModel lifecycle)

```text
App launch
    │
    ├─ model not in cache ──► notDownloaded
    │                              │
    │                         User presses Record
    │                              │
    │                         downloading(progress: 0.0 → 1.0)
    │                              │
    │                         downloaded ──► loading ──► active
    │
    └─ model in cache ──────► loading ──► active
```

---

## Relationships

```
WhisperModelManager
    │
    ├── owns: RecognitionModel (state + cached WhisperKit instance)
    ├── publishes: AsyncStream<Double> (download progress)
    └── returns: WhisperKit (loaded instance)

WhisperSpeechListener
    │
    ├── depends on: WhisperModelManager (for WhisperKit instance)
    ├── produces: AsyncStream<SpeechSegment>
    └── maps: WhisperKit segments → SpeechSegment

TranscriptionViewModel
    │
    ├── reads: AsyncStream<Double> (via DependencyContainer binding)
    └── sets: translatorState = .modelDownloading(progress:)
```

---

## Persistence

- **RecognitionModel cache**: Managed entirely by WhisperKit at  
  `~/Documents/huggingface/models--argmaxinc--whisperkit-coreml/`.  
  The app never writes directly to this location.
- **No SwiftData entities added**: Model state is ephemeral — derived from filesystem presence on each launch.
- **Existing persistence** (SwiftData `ConversationRecord`): Unchanged by this feature.
