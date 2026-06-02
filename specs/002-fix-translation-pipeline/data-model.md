# Data Model: Fix Translation Pipeline

**Date**: 2026-06-01 | **Branch**: `002-fix-translation-pipeline`

All data is in-memory only. No persistence layer.

---

## Entities

### SpeechSegment *(unchanged)*

Carries one ASR update from the recognition engine.

| Field | Type | Description |
|-------|------|-------------|
| text | String | Full accumulated transcript so far (not a delta) |
| isFinal | Bool | True when ASR has committed this transcription |
| confidence | Float | Average segment confidence [0.0–1.0] |

**Validation**: `text` must not be empty before yielding to the stream (enforced in `ContinuousSpeechListener`).

---

### StablePhrase *(implicit — yielded as `String` from `NLPSegmenterService`)*

A complete phrase segment ready for translation.

| Field | Type | Description |
|-------|------|-------------|
| text | String | Trimmed phrase, ≥ 2 words (configurable via `minShortPhraseWords`) |

**Constraints**:
- Must be a suffix delta over the already-committed text — never includes re-emitted prior content
- Must not be empty or whitespace-only
- Must have ≥ `minShortPhraseWords` words, or be explicitly force-emitted (flush on stop)

---

### QualitySnapshot *(unchanged)*

Aggregated ASR quality signals for one session.

| Field | Type | Description |
|-------|------|-------------|
| revisionRate | Double | ASR revisions per minute |
| avgStabilityDelay | TimeInterval | Average gap between ASR updates |
| avgWordsPerSecond | Double | Speech rate |
| avgConfidence | Float | Average recognition confidence |
| avgFragmentation | Double | Fraction of likely-truncated words |
| totalRevisions | Int | Total correction count in session |

---

### TranslatorState *(extended)*

Enum representing the pipeline's current operational state.

| Case | Trigger | UI Meaning |
|------|---------|------------|
| `.idle` | App start / recording stopped | Record button active, panes show placeholder |
| `.inFlight` | Phrase sent to translation engine | Optional spinner or indicator |
| `.error` | Generic ASR / audio engine error | Alert shown, recording stopped |
| `.permissionDenied` *(new)* | Microphone or speech recognition auth denied | Descriptive alert, directs user to System Settings |
| `.modelUnavailable` *(new)* | Apple Translation model not downloaded | Banner in ES pane asking user to download |

---

## State Transitions

```text
                  ┌─────────────────────────────────────────┐
                  │                                         │
              [permission                             [3rd restart
               denied]                                 succeeds]
                  │                                         │
  idle ──[tap Record]──► authorising ──[granted]──► recording ◄────┐
   ▲                          │                      │    ▲        │
   │                    [denied]                 [phrase  │        │
   │                          │                  ready]  │    [translation
   │                          ▼                     │    │      done]
   │                  permissionDenied          inFlight ─┘        │
   │                                                │              │
   │                                           [model              │
   │                                         unavailable]          │
   │                                                │              │
   │                                        modelUnavailable       │
   │                                                               │
   │◄──────────────[tap Stop / ASR error]──────────────────────────┘
   │                          │
   │                       stopping
   │                          │
   └────────[all tasks done]──┘
```

---

## Session Lifecycle

```text
startRecording()
  1. Reset all buffers and phrase sets
  2. Create AsyncStream<String> (translationRequests) with its Continuation
  3. Set isRecording = true
  4. Launch transcriptionTask:
     a. await executeBoth() → (rawStream, segmentedStream)
     b. Launch uiTask: for await segment in rawStream → update currentBuffer
     c. for await phrase in segmentedStream → yield to translationContinuation

stopRecording()
  1. isRecording = false
  2. translationContinuation.finish()  ← closes translationRequests stream → .translationTask exits
  3. transcriptionTask.cancel()
  4. Task { await transcribeUseCase.stop() }
     → repository.stopTranscription()
       → listener.stop()
         → continuation.finish()  ← closes source stream → pump Task exits → rawStream + segInput finish
           → NLPSegmenterService for-await exits → segmentedStream finishes → uiTask exits
```

---

## Concurrency Map

| Component | Isolation | Notes |
|-----------|-----------|-------|
| `ContinuousSpeechListener` | `actor` | ASR delegate callback dispatches `Task { await self.updateTranscript(...) }` |
| `SpeechRepository` | `final class` (thin wrapper, `@MainActor`) | Only delegates to actor; no state |
| `QualityMetricsService` | `actor` | Safe for concurrent metric recording |
| `NLPSegmenterService` | `actor` *(changed from `final class`)* | Moves segmentation off MainActor |
| `TranscribeAudioUseCase` | `final class` (`@MainActor`) | Holds pump Task reference; safe as long as methods are called on MainActor |
| `TranscriptionViewModel` | `@MainActor @Observable` | All @Published state mutations on MainActor |
| `LiveTranscriptionView` | SwiftUI `View` (`@MainActor`) | `.translationTask` closure runs on MainActor; calls `session.translate` which suspends |

---

## Configuration Constants

All tunable values live in `NLPSegmenterService` (or may be promoted to a config struct):

| Constant | Default | Description |
|----------|---------|-------------|
| `stabilityDelay` | 700 ms | Silence-triggered flush timer (normal quality) |
| `stabilityDelayLowQuality` | 1 200 ms | Silence-triggered flush timer (low quality detected) |
| `longSentenceWordThreshold` | 15 words | Force clause-marker cut above this length |
| `minShortPhraseWords` | 2 words | Minimum words for a phrase to be emitted |
| `maxPendingInterval` | 6.0 s | Hard timeout — flush even without silence |
| `maxFlushDelay` | 5.0 s | Max retention on recording stop |
| `maxTranslatedSentences` | 30 | Sentence buffer cap in ViewModel |
| `maxEmittedPhrases` | 50 | EN phrase history cap in ViewModel |
