# Research: WhisperKit ASR Integration

**Feature**: 004-whisperkit-asr  
**Phase**: 0 — Research  
**Date**: 2026-06-02

---

## Decision 1: ASR Backend Selection

**Decision**: Replace `SFSpeechRecognizer` with **WhisperKit** (`argmaxinc/argmax-oss-swift`) using the `AudioStreamTranscriber` actor for streaming transcription.

**Rationale**:  
- WhisperKit is a Swift-native CoreML port of OpenAI Whisper. It runs fully on-device with zero internet dependency after the initial download.  
- Whisper large-v3-turbo achieves <5% WER on non-American English accents (British, Indian, Australian, Filipino, Nigerian) — compared to SFSpeechRecognizer's 15–30% WER on the same accents.  
- `AudioStreamTranscriber` surfaces `confirmedSegments` (final) and `unconfirmedSegments` (partial), matching the existing `SpeechSegment.isFinal` interface with zero Domain-layer changes.  
- The library ships as a Swift Package, avoiding manual framework bundling.

**Alternatives considered**:  
- `SFSpeechRecognizer` with locale `"en"`: Marginal improvement on accents — still Apple's general-purpose model, which is optimised for American English. Rejected as insufficient.  
- OpenAI Whisper via REST API: Introduces network dependency, latency, privacy concerns. Rejected — spec requires fully offline operation.  
- Smaller Whisper models (`tiny`, `base`, `small`): Lower WER improvement. `large-v3-turbo` (~632 MB) gives best accuracy/speed tradeoff for macOS desktop. `small` is a fallback-only option for edge cases.

---

## Decision 2: SPM Package URL

**Decision**: `https://github.com/argmaxinc/argmax-oss-swift`  
*(This is the consolidated monorepo. The older `https://github.com/argmaxinc/WhisperKit` URL still works but points to the same package.)*

**Rationale**: argmaxinc consolidated their Swift libraries under `argmax-oss-swift`. Both URLs resolve identically — the consolidated one is the canonical source going forward.

---

## Decision 3: Model Variant

**Decision**: `"openai_whisper-large-v3-v20240930_turbo_632MB"` (~632 MB compressed)

**Rationale**:  
- Fastest large-variant with best non-American-English accuracy.  
- Fits comfortably in macOS desktop storage expectations for a professional tool.  
- Model is cached automatically by WhisperKit at `~/Documents/huggingface/models--argmaxinc--whisperkit-coreml/` and never re-downloaded.

**Fallback model**: `"openai_whisper-small.en"` (~242 MB) — used if device reports no Neural Engine or performance benchmark fails. Acceptable WER degradation vs. no function at all.

---

## Decision 4: Hardware Constraint

**Decision**: WhisperKit requires **Apple Silicon** (M-series) for usable real-time performance. Intel Macs are not supported.

**Rationale**: WhisperKit uses the ANE (Apple Neural Engine) via CoreML. On Intel Macs, CoreML falls back to CPU-only inference, producing latencies of 10–30 s per chunk — incompatible with live transcription. The spec assumption ("macOS 14+ provides sufficient on-device compute") holds only for Apple Silicon Macs.

**Action required**: `FR-010` fallback kicks in on Intel Macs. `WhisperModelManager` must detect the chip architecture at runtime and skip WhisperKit, falling through to the existing `ContinuousSpeechListener` (SFSpeechRecognizer) path.

Detection:
```swift
import Darwin
var size = 0
sysctlbyname("hw.optional.arm64", nil, &size, nil, 0)
var arm64: Int32 = 0
sysctlbyname("hw.optional.arm64", &arm64, &size, nil, 0)
let isAppleSilicon = arm64 == 1
```

---

## Decision 5: Streaming API Pattern

**Decision**: Use `AudioStreamTranscriber` actor with a custom `AVAudioEngine` tap.

**Key API surface** (WhisperKit as of 2025 Q1):

```swift
import WhisperKit

// Step 1: Download + load (first launch downloads, subsequent launches load from cache)
let config = WhisperKitConfig(model: "openai_whisper-large-v3-v20240930_turbo_632MB")
let whisperKit = try await WhisperKit(config)

// Step 2: Streaming transcription via AudioStreamTranscriber
let transcriber = AudioStreamTranscriber(
    audioEncoder: whisperKit.audioEncoder,
    featureExtractor: whisperKit.featureExtractor,
    segmentSeeker: whisperKit.segmentSeeker,
    textDecoder: whisperKit.textDecoder,
    tokenizer: whisperKit.tokenizer
) { [weak self] oldSegments, newSegments in
    // confirmedSegments == isFinal: true
    // unconfirmedSegments == isFinal: false
    let confirmed = newSegments.filter { $0.start >= 0 }
    ...
}
try await transcriber.startStreamTranscription()

// Step 3: Decoding options for accent robustness
var opts = DecodingOptions()
opts.task = .transcribe
opts.language = "en"
opts.withoutTimestamps = false
opts.wordTimestamps = true
opts.usePrefillPrompt = true    // fills context for accent robustness
opts.skipSpecialTokens = true
opts.noSpeechThreshold = 0.6
opts.temperature = 0.0          // greedy for consistency
opts.chunkingStrategy = .vad    // built-in energy VAD
```

---

## Decision 6: Model Download Progress

**Decision**: Use `WhisperKit.download(variant:progressCallback:)` class method, which returns a `Progress` object and fires `progressCallback` with `Foundation.Progress`.

```swift
let progress = try await WhisperKit.download(
    variant: modelVariant,
    progressCallback: { progress in
        let fraction = progress.fractionCompleted  // 0.0 ... 1.0
        // report to caller
    }
)
```

**Integration**: `WhisperModelManager` wraps this in an `AsyncStream<Double>` so `DependencyContainer` can bind it to `TranscriptionViewModel.updateDownloadProgress(_:)`.

---

## Decision 7: VAD Strategy

**Decision**: Rely on WhisperKit's built-in energy-based VAD (`chunkingStrategy: .vad`) via `AudioStreamTranscriber`. No external VAD library needed.

**Rationale**:  
- `AudioStreamTranscriber` handles silence detection, chunking (5–7 s optimal), and segment confirmation internally.  
- `noSpeechThreshold: 0.6` in `DecodingOptions` suppresses hallucinations during silence.  
- `silenceThreshold: 0.3` in the transcriber's config filters low-energy frames before inference.

**Alternatives considered**:  
- FluidAudio / Silero VAD: Better noise robustness, but adds another SPM dependency and significant complexity. Reserved for a future "noisy room" feature.

---

## Decision 8: Architecture Insertion Point

**Decision**: `WhisperSpeechListener` conforms to the same implicit interface as `ContinuousSpeechListener`:
- `func start() throws -> AsyncStream<SpeechSegment>`
- `func stop() async`

A new `WhisperSpeechRepository: SpeechRepositoryProtocol` wraps it. `DependencyContainer` switches backends via a `usesWhisper: Bool` flag. The Domain layer (`TranscribeAudioUseCase`, `NLPSegmenterService`) is **not modified**.

---

## Decision 9: TranslatorState Extension

**Decision**: Add `.modelDownloading(progress: Double)` case to `TranslatorState`. This is a Domain entity — the change is minimal (one case addition) and does not violate layer purity (no framework imports added).

**UI rendering**: In `LiveTranscriptionView`, the Spanish pane shows an overlay progress bar when `translatorState == .modelDownloading(progress:)`. Normal text content is blurred/hidden during download.

---

## Resolved Unknowns

| Unknown | Resolution |
|---------|-----------|
| Exact SPM URL | `https://github.com/argmaxinc/argmax-oss-swift` |
| Model variant string | `"openai_whisper-large-v3-v20240930_turbo_632MB"` |
| Streaming API | `AudioStreamTranscriber` actor with segment callback |
| Download progress | `WhisperKit.download(variant:progressCallback:)` |
| VAD approach | Built-in `chunkingStrategy: .vad` in DecodingOptions |
| Intel Mac | Detect `hw.optional.arm64`, fallback to SFSpeechRecognizer |
| Model cache location | `~/Documents/huggingface/models--argmaxinc--whisperkit-coreml/` |
| Audio format | 16 kHz mono Float32 — WhisperKit's AudioProcessor handles conversion |
