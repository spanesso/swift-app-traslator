# Contract: WhisperModelManager

**Layer**: Data  
**Type**: Swift `actor`  
**File**: `TranslatorApp/Data/WhisperModelManager.swift`

---

## Interface

```swift
actor WhisperModelManager {
    /// Real-time download progress stream (0.0–1.0).
    /// Emits values only during an active download; completes when download finishes.
    let downloadProgress: AsyncStream<Double>

    init(modelVariant: String)

    /// Returns a fully loaded WhisperKit instance.
    /// - On first call: downloads (if needed) then loads the model.
    /// - On subsequent calls: returns the cached instance immediately.
    /// - Throws if hardware is unsupported or download/load fails.
    func loadModel() async throws -> WhisperKit

    /// Cancels any in-flight download or loading operation.
    func cancelLoading() async
}
```

---

## Behavioral Contract

### `loadModel()`

**State machine**:

1. `notDownloaded` → calls `WhisperKit.download(variant:progressCallback:)`:
   - Each progress callback fires a value into `downloadProgress` stream.
   - On completion → transitions to `downloaded`.
2. `downloaded` → calls `WhisperKit(config:)` async initializer:
   - Loads CoreML models into memory and ANE.
   - On completion → transitions to `active`.
3. `active` → returns cached `WhisperKit` instance immediately (no async work).

**Concurrent calls**: If two callers invoke `loadModel()` simultaneously, only one download/load runs. The second caller awaits the same underlying task via stored `Task<WhisperKit, Error>`.

### `cancelLoading()`

- Cancels the download/load task if in progress.
- Transitions state back to `notDownloaded`.
- Subsequent `loadModel()` call restarts from scratch.

### `downloadProgress` Stream

- Created once in `init()`.
- Values emitted only when a download is actively running.
- Does NOT complete after a download; the stream lives as long as the manager.
- On subsequent launches (model already cached): no values are emitted — stream stays open but idle.

---

## Hardware Detection

```swift
// Called once in init()
private static func isAppleSilicon() -> Bool {
    var size = 0
    sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
    var arm64: Int32 = 0
    sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
    return arm64 == 1
}
```

If `isAppleSilicon()` returns `false`, `loadModel()` immediately throws `WhisperASRError.unsupportedHardware`.

---

## Error Conditions

| Error | Condition | Recovery |
|-------|-----------|----------|
| `WhisperASRError.unsupportedHardware` | Intel Mac detected | Caller switches to SFSpeechRecognizer |
| `WhisperASRError.downloadFailed(Error)` | Network failure or disk full | Surface retry UI |
| `WhisperASRError.modelLoadFailed(Error)` | CoreML init fails | Surface error state |

---

## Caching

- WhisperKit caches models at `~/Documents/huggingface/models--argmaxinc--whisperkit-coreml/`.
- `WhisperModelManager` checks for cached files before calling `WhisperKit.download`.
- Cache check: `WhisperKit.recommendedModels()` or filesystem probe of the cache directory.
- The app never manually manages this cache directory.

---

## Constraints

- No Domain layer imports.
- `downloadProgress` stream must never block callers — use a buffered `AsyncStream` with `bufferingPolicy: .bufferingNewest(1)`.
- The cached `WhisperKit` instance is never shared across concurrent `start()` calls — `WhisperSpeechListener` owns one transcription session at a time.
