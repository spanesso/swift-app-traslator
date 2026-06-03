# Quickstart: WhisperKit ASR Integration

**Feature**: 004-whisperkit-asr  
**Date**: 2026-06-02

---

## Integration Scenarios

### Scenario 1 — First Launch (model not cached)

```
User opens app
    │
    ▼
DependencyContainer.init()
    │  creates WhisperModelManager(modelVariant: "openai_whisper-large-v3-v20240930_turbo_632MB")
    │  creates WhisperSpeechListener(modelManager: manager)
    │  binds manager.downloadProgress → viewModel.updateDownloadProgress(_:)
    ▼
LiveTranscriptionView appears
    │
    ▼
User presses Record button
    │
    ▼
TranscriptionViewModel.toggleRecording()
    │  calls transcribeUseCase.executeBoth()
    ▼
WhisperSpeechListener.start()
    │  calls modelManager.loadModel()
    ▼
WhisperModelManager detects model not cached
    │  calls WhisperKit.download(variant:progressCallback:)
    │  fires downloadProgress: 0.0, 0.1, ... 1.0
    ▼
DependencyContainer download binding fires
    │  calls viewModel.updateDownloadProgress(0.0 ... 1.0)
    ▼
TranscriptionViewModel sets translatorState = .modelDownloading(progress: p)
    ▼
LiveTranscriptionView shows progress bar overlay in Spanish pane
    │  "Downloading recognition model… 45%"
    ▼
Download completes → modelManager transitions to .active
    ▼
WhisperSpeechListener receives WhisperKit instance
    │  starts AVAudioEngine + AudioStreamTranscriber
    ▼
SpeechSegment stream begins → normal transcription flow
    ▼
viewModel.translatorState = .idle
LiveTranscriptionView hides progress overlay → transcription text appears
```

---

### Scenario 2 — Subsequent Launch (model cached)

```
User opens app
    ▼
WhisperModelManager.init()
    │  detects model in ~/Documents/huggingface/...
    │  no download progress emitted
    ▼
User presses Record (within 5 s)
    ▼
WhisperSpeechListener.start()
    │  modelManager.loadModel() — loads from disk (~2–4 s on Apple Silicon)
    ▼
AudioStreamTranscriber starts
    ▼
First SpeechSegment emitted — user sees transcription text
```

**Key**: No download indicator shown. User sees idle → inFlight states only.

---

### Scenario 3 — Long Session (15-minute meeting)

```
Recording active for 5+ minutes
    │
    ├─ AudioStreamTranscriber emits segments continuously
    │   confirmedSegments → isFinal: true → translation pipeline
    │   unconfirmedSegments → isFinal: false → currentBuffer
    │
    ├─ WhisperSpeechListener watchdog checks every 30 s
    │   if no segments: restarts AVAudioEngine silently
    │   AsyncStream continues (no finish() called)
    │
    └─ translatedSentences preserved across internal restarts
```

---

### Scenario 4 — Intel Mac (unsupported hardware)

```
WhisperModelManager.init() detects Intel CPU
    ▼
modelManager.loadModel() throws .unsupportedHardware
    ▼
DependencyContainer catches error
    │  usesWhisper = false (runtime fallback)
    │  switches to SpeechRepository(listener: ContinuousSpeechListener)
    ▼
App continues with SFSpeechRecognizer (locale: "en")
No WhisperKit code paths execute
```

---

### Scenario 5 — Download Interrupted (network loss at 60%)

```
Download at 60%
Network drops
    ▼
WhisperKit.download() throws URLError(.networkConnectionLost)
    ▼
WhisperModelManager transitions state → .notDownloaded
    ▼
viewModel.translatorState = .error
errorMessage = "Download failed. Check your connection and try again."
    ▼
User taps Record again
    ▼
WhisperKit resumes from nearest checkpoint (native behavior)
```

---

## SPM Package Setup (one-time, in Xcode)

1. Xcode → File → Add Package Dependencies
2. Paste URL: `https://github.com/argmaxinc/argmax-oss-swift`
3. Select version: Up to Next Major from `2.0.0`
4. Add to target: `TranslatorApp`

After adding, add all new `.swift` files to the `TranslatorApp` target:  
File → Add Files to "TranslatorApp" → select all files in `TranslatorApp/Data/`.

---

## Files To Create

| File | Lines | Description |
|------|-------|-------------|
| `Data/WhisperModelManager.swift` | ≤250 | Model download/load/cache actor |
| `Data/WhisperSpeechListener.swift` | ≤250 | Streaming transcription actor |
| `Data/WhisperSpeechListener+Audio.swift` | ≤250 | AVAudioEngine setup (split if needed) |
| `Data/Repository/WhisperSpeechRepository.swift` | ≤100 | SpeechRepositoryProtocol adapter |

## Files To Modify

| File | Change |
|------|--------|
| `Domain/Entities/TranslatorState.swift` | Add `.modelDownloading(progress: Double)` case |
| `Data/ContinuousSpeechListener.swift` | Change locale `"en-US"` → `"en"` |
| `App/DependencyContainer.swift` | Wire WhisperKit backend + download progress binding |
| `Presentation/ViewModels/TranscriptionViewModel.swift` | Handle `.modelDownloading` state |
| `Presentation/Views/LiveTranscriptionView.swift` | Show download progress overlay |

## Files NOT To Touch

- `SpeechRepositoryProtocol.swift`
- `SpeechSegment.swift`
- `TranscribeAudioUseCase.swift`
- `NLPSegmenterService.swift` / `NLPSegmenterServiceProtocol.swift`
- All Views not listed above
- All persistence files
