# Contract: WhisperSpeechListener

**Layer**: Data  
**Type**: Swift `actor`  
**File**: `TranslatorApp/Data/WhisperSpeechListener.swift`

---

## Interface

```swift
actor WhisperSpeechListener {
    init(modelManager: WhisperModelManager)

    /// Starts the transcription pipeline.
    /// - If the model is not yet downloaded, blocks until download + load completes.
    /// - Emits SpeechSegment values continuously until stop() is called.
    /// - Never calls continuation.finish() except in stop() or on unrecoverable error.
    func start() async throws -> AsyncStream<SpeechSegment>

    /// Gracefully stops transcription. Finishes the AsyncStream continuation.
    func stop() async
}
```

---

## Behavioral Contract

### `start()`

1. Requests `WhisperKit` instance from `WhisperModelManager.loadModel()`.  
   - During model download: `modelManager` streams progress via `downloadProgress` — the listener does NOT emit `SpeechSegment` during this phase.  
   - If model load fails with hardware error (Intel Mac): throws `WhisperASRError.unsupportedHardware`.
2. Once model is ready:  
   - Configures `AVAudioEngine` at 16 kHz mono Float32.  
   - Starts `AudioStreamTranscriber`.  
   - Begins emitting `SpeechSegment` values into the returned `AsyncStream`.
3. Partial results (`unconfirmedSegments`) → emitted with `isFinal: false`.  
4. Final results (`confirmedSegments`) → emitted with `isFinal: true`.
5. Watchdog: if no segment is emitted in 30 s, the internal audio pipeline is restarted silently (stream stays alive).

### `stop()`

1. Cancels any in-flight model loading task.
2. Stops `AudioStreamTranscriber` and `AVAudioEngine`.
3. Calls `continuation.finish()` to terminate the `AsyncStream`.
4. Resets internal state for a clean `start()` on the next session.

### Error Conditions

| Error | Thrown From | Recovery |
|-------|-------------|----------|
| `WhisperASRError.unsupportedHardware` | `start()` | Caller falls back to SFSpeechRecognizer path |
| `WhisperASRError.modelLoadFailed(Error)` | `start()` | Emit `.error` TranslatorState; allow retry |
| `WhisperASRError.audioEngineSetupFailed(Error)` | `start()` | Emit `.error` TranslatorState |

---

## Thread Safety

- All mutable state is isolated within the `actor`.
- `AsyncStream.Continuation` operations are `nonisolated`-safe.
- `AVAudioEngine` tap callback (non-isolated) marshals buffers to the actor via `Task { await self.processBuffer(...) }`.

---

## Constraints

- Max 250 lines per file. Overflow goes to `WhisperSpeechListener+Audio.swift`.
- Zero WhisperKit imports allowed in any Domain layer file.
- Domain `SpeechSegment` is the only cross-layer type.
