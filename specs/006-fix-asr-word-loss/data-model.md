# Phase 1 — Data Model

**Feature**: 006-fix-asr-word-loss

This is a corrective feature. It **reuses** the feature-005 data model almost entirely and
introduces exactly one new runtime entity plus a set of behavioral rule changes on existing
types. Nothing in the Domain dependency direction changes.

---

## 1. New runtime entity

### 1.1 `AudioRingBuffer` (Data layer, actor-local — H1)

Fixed-capacity rolling store of the most recent captured audio, used to bridge the
recognizer-restart gap without stopping the tap.

| Field / behavior | Description |
|---|---|
| capacity | Duration-based, ~1.5 s of audio at the tap's native sample rate (configurable constant). |
| append(_:) | Push the latest `AVAudioPCMBuffer` (native format); evict oldest beyond capacity. |
| drain() → [AVAudioPCMBuffer] | Return buffered frames in chronological order to replay into a fresh request; clears on drain. |
| isolation | Lives on the capture path (engine actor / cameraQueue-equivalent), never MainActor. |
| Sendable | Holds value copies of buffer frames; no `@unchecked Sendable`. |

**Placement**: `TranslatorApp/Data/Audio/AudioRingBuffer.swift`. Domain-agnostic; imports
`AVFoundation`, `Foundation` only.

**Lifecycle at restart** (replaces the lossy sequence at `ContinuousSpeechListener.swift:126–157`):
1. Build + start the new `SFSpeechAudioBufferRecognitionRequest`.
2. `drain()` the ring buffer and append its frames to the new request first.
3. Redirect the live tap to the new request.
4. End/cancel the old request last.

---

## 2. Existing entities — reused unchanged

- **`SpeechSegment`** (`text`, `isFinal`, `isHypothesis`, `confidence`, `tokens`): unchanged
  shape. Behavioral change only: WhisperKit **confirmed** segments are emitted with
  `isFinal: true` (not `isHypothesis: true`) so they reach the segmenter/translation (W3).
- **`EngineId`** (`legacyAppleSFSpeech`, `appleSpeechAnalyzer`, `whisperKitTurbo`,
  `whisperKitSmall`): unchanged. `whisperKitSmall` may become active if the harness justifies a
  smaller model (P2, optional). A new `speechAnalyzer` case (real API) is added in Phase 3.
- **`ModelInstallState`** (`notRequested | awaitingConsent | downloading(progress:) |
  installed(version:,sizeBytes:) | declined | failed(reason:)`): unchanged. Now driven by the
  **actual** model download/preload (W4) instead of a decoupled coordinator flag.
- **`EnginePreference`** (`appleOnly | auto | whisperPreferred`): unchanged.
- **`DeviceCapabilities`** (`supportsA17Pro`, `supportsEnhancedFrameworks`): unchanged;
  `supportsEnhancedFrameworks` becomes the Tier-0 gate in Phase 3.
- **`SpeechEngineOptions` / `SpeechEngineError`**: unchanged contract.
- **`SessionQualityRecord`, `ConversationRecord`** (SwiftData): unchanged.
- **Evaluation artifacts** (`EvaluationCorpusManifest`, `EvaluationReport`, `EvaluationDelta`,
  `WERCalculator`, `EntityExtractor`): exist on disk; Phase 0 only **wires them into a test
  target** — no schema change.

---

## 3. Behavioral rule changes on existing types

| Type / location | Current rule | New rule | Finding |
|---|---|---|---|
| `QualityMetricsService` `:56–60,99,112` | averages confidence from all segments incl. partials (0.0) | ignore partial-result confidence; feed only final/non-zero into `recordConfidence` | H4 |
| `NLPSegmenterService` `:49–54` | drop `wordCount < 2 && !isFinal` | allow ≤1-word emit when the utterance is complete (terminator/stability flush), not only on `isFinal` | 1-word |
| `NLPSegmenterService` `:28,56–61` | `pendingHypothesis` buffered, never consumed (dead) | reachable once confirmed segments arrive as final, or removed as dead code | W3 |
| `TranscribeAudioUseCase` `:48` | `guard !isHypothesis` excludes mid-session WhisperKit output | WhisperKit confirmed segments arrive as `isFinal` and pass the guard | W2/W3 |
| `TranscriptionViewModel` `:65,164,178` | `latestSegmentConfidence` (mutable) stamped onto `TranslationRequest` | carry confidence on the phrase/segment through to the translation request | UI confidence |
| `VADGate` (→ `EmptySegmentFilter`) | applied twice (engine `:51` + repo `:27`) | single application; renamed to reflect text-empty filtering | VAD |
| AVAudioSession (`ContinuousSpeechListener.swift:55–59`, `AppleSpeechAnalyzerEngine`) | mode `.measurement` | mode `.spokenAudio` (fallback `.default`) | H2 |
| `SFSpeechAudioBufferRecognitionRequest` (`ContinuousSpeechListener.swift:62–107`) | only `shouldReportPartialResults` | + `taskHint = .dictation`, `addsPunctuation = true`, `contextualStrings` | H3 |
| `WhisperKitEngine` `:75–84` | 16 kHz tap format (invalid) | native-format tap + `AVAudioConverter` → 16 kHz mono | W1 |
| `WhisperKitEngine` `:101–117,150,153` | unbounded buffer, full re-transcribe, hypothesis-only | `AudioStreamTranscriber`, bounded, confirmed-as-final | W2/W3/W6 |
| `WhisperKitEngine` `:126` | `firstTokenLogProbThreshold: -1.5` | removed/relaxed, corpus-validated | W5 |
| `WhisperKitEngine` `:34–42` + `BackgroundAssetsCoordinator` `:92–106` | model download decoupled, no unzip, no `modelFolder` | unified: preload-on-select, progress→`ModelInstallState`, correct URL/unzip or built-in download | W4 |

---

## 4. State transitions worth pinning down

### 4.1 Recognizer restart (classic engine, H1)
```
capturing ──(isFinal || watchdog≈65s || error)──▶ restarting
restarting: startNewRequest → drain(ringBuffer)→newRequest → redirectTap → endOldRequest ──▶ capturing
INVARIANT: no tap buffer is appended to a dead/absent request; carry-over replayed exactly once.
```

### 4.2 Engine selection (adds Tier 0 in P3)
```
appleOnly                         → ConsolidatedClassicEngine
auto/whisperPreferred + supportsEnhancedFrameworks (P3) → SpeechAnalyzerEngine   [Tier 0]
auto/whisperPreferred + supportsA17Pro + model usable   → WhisperKitEngine       [Tier 1]
otherwise                          → ConsolidatedClassicEngine                    [fallback]
```

### 4.3 WhisperKit model install (W4)
```
notRequested → awaitingConsent → downloading(progress) → (verify loadable) → installed
                                        │
                                        └─(fail/cancel)→ failed(reason) / declined
Engine selection requires installed AND a model that actually loads (not just the flag).
Preload happens on engine selection, never on record.
```

---

## 5. Files introduced / changed

| File | Change |
|---|---|
| `TranslatorApp/Data/Audio/AudioRingBuffer.swift` | **New** (P1) |
| `TranslatorApp/Data/SpeechEngines/SpeechAnalyzerEngine.swift` | **New** (P3) |
| `TranslatorApp/Data/ContinuousSpeechListener.swift` | H1, H2, H3 |
| `TranslatorApp/Data/SpeechEngines/AppleSpeechAnalyzerEngine.swift` | H5 + consolidation (may be retired) |
| `TranslatorApp/Data/SpeechEngines/LegacySFSpeechEngine.swift` | route to consolidated engine |
| `TranslatorApp/Data/SpeechEngines/WhisperKitEngine.swift` | W1, W2/W3, W5, W6 |
| `TranslatorApp/Data/Coordinators/BackgroundAssetsCoordinator.swift` | W4 |
| `TranslatorApp/Data/Audio/VADGate.swift` | rename → `EmptySegmentFilter`; de-duplicate |
| `TranslatorApp/Data/SpeechRepository.swift` | remove duplicate VAD |
| `TranslatorApp/Domain/Services/QualityMetricsService.swift` | H4 |
| `TranslatorApp/Domain/Services/NLPSegmenterService.swift` | 1-word emit; pendingHypothesis |
| `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift` | confirmed-as-final |
| `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` | confidence-to-phrase |
| `TranslatorApp/App/DependencyContainer.swift` | engine-log; Tier-0 wiring (P3) |
| `TranslatorApp.xcodeproj` | evaluation test target wiring (P0); SPM version pin (P2) |
