# Phase 1 — Data Model

**Feature**: `005-accent-robust-asr`
**Date**: 2026-06-17
**Scope**: Domain entities, runtime state transitions, SwiftData persistence schema, evaluation-harness JSON.

Everything here is **Domain-layer pure** — no `Speech`, no `AVFoundation`, no `WhisperKit`, no `FoundationModels`, no SwiftUI. Concrete engines map *into* these types; the spec contract is judged against these types.

---

## 1. Runtime entities (in-memory, Sendable)

### 1.1 `TranscriptToken`

The unit the UI tints by opacity and the unit the corrector edits or locks.

```swift
struct TranscriptToken: Sendable, Hashable {
    let text: String                  // e.g. "tomorrow"
    let confidence: Float             // 0.0 ... 1.0, engine-reported
    let startTime: TimeInterval?      // seconds from session start; nil if engine doesn't expose it
    let endTime: TimeInterval?
    let isLocked: Bool                // true once a corrector pass locked it; cannot be edited downstream
}
```

**Why `startTime`/`endTime` optional**: iOS 26 `SpeechTranscriber` and WhisperKit both expose timing; the legacy `SFSpeechRecognizer` fallback path on older iOS does not. Optional preserves the contract across engines.

**Why `isLocked`**: the corrector marks high-confidence tokens and named entities as locked so a second pass (or a downstream display) knows it cannot be edited.

### 1.2 `SpeechSegment` (extended)

The existing entity (`text: String, isFinal: Bool, confidence: Float`) is preserved as a backward-compatible aggregate, with **two new optional fields**. Code that only reads `text` / `isFinal` / `confidence` continues to work.

```swift
struct SpeechSegment: Sendable {
    let text: String                  // joined token text (whitespace-canonical)
    let isFinal: Bool                 // engine's "this won't be revised" signal
    let confidence: Float             // mean of token confidences (or engine aggregate)
    let tokens: [TranscriptToken]     // NEW. Empty when engine doesn't expose tokens.
    let source: EngineId              // NEW. Which engine produced this segment.
    let isHypothesis: Bool            // NEW (default false). True for WhisperKit hypothesis stream.

    nonisolated init(text: String,
                     isFinal: Bool,
                     confidence: Float = 1.0,
                     tokens: [TranscriptToken] = [],
                     source: EngineId = .legacyAppleSFSpeech,
                     isHypothesis: Bool = false)
}
```

**Migration discipline**: every call site that currently constructs `SpeechSegment(text:isFinal:confidence:)` continues to compile (defaulted args). Engines that DO produce tokens populate the new fields.

### 1.3 `EngineId`

```swift
enum EngineId: String, Sendable, Codable {
    case legacyAppleSFSpeech      // pre-iOS 26 fallback (current ContinuousSpeechListener)
    case appleSpeechAnalyzer      // iOS 26 SpeechAnalyzer/SpeechTranscriber
    case whisperKitTurbo          // WhisperKit large-v3-turbo (compressed)
    case whisperKitSmall          // WhisperKit small (in-bundle warm-up)
}
```

Carried on every segment so the diagnostic harness and logs can attribute outcomes to the engine that produced them.

### 1.4 `AccentGroup`

```swift
enum AccentGroup: String, Sendable, Codable, CaseIterable {
    case native           // baseline / regression guard
    case italian
    case indianSouthAsian
    case latino           // Spanish-influenced English
    case other            // best-effort; not in headline metrics
    case unknown          // when no detection has run yet
}
```

Used in two places: (a) by the diagnostic harness to break down metrics, (b) **optionally** as a runtime hint when the user has set a preference (FR-013). Not auto-detected from audio in v1.

### 1.5 `EnginePreference`

```swift
enum EnginePreference: String, Sendable, Codable {
    case auto             // pick best available; this is the default
    case appleOnly        // force Tier 0 (no download, no Whisper)
    case whisperPreferred // force Tier 1 when available
}
```

Persisted in user defaults (key: `engine.preference`). Default `.auto`.

### 1.6 `ModelInstallState`

State machine for the `BackgroundAssets`-managed WhisperKit model.

```swift
enum ModelInstallState: Sendable, Equatable {
    case notRequested                                 // never asked the user
    case awaitingConsent                              // first-run prompt visible
    case downloading(progress: Double)                // 0.0 ... 1.0
    case installed(version: String, sizeBytes: Int64) // ready to use
    case declined                                     // user said no; stay on Tier 0
    case failed(reason: ModelInstallFailure)
}

enum ModelInstallFailure: Sendable, Equatable {
    case networkUnavailable
    case deviceUnsupported   // device older than A17 Pro
    case insufficientStorage
    case canceled
    case unknown(String)
}
```

**Transitions** (the only legal ones — others are bugs):

```
notRequested
  └─→ awaitingConsent
       ├─→ declined                (user dismissed)
       └─→ downloading(0.0)
            ├─→ downloading(p)     (progress ticks)
            │    └─→ installed(...) (on completion)
            └─→ failed(reason)
                 └─→ awaitingConsent (after user retry)
```

`declined` and `installed` are terminal until the user explicitly retries from settings.

### 1.7 `TranslatorState` (extension)

The existing enum gains two cases — current cases are preserved.

```swift
enum TranslatorState: Sendable, Equatable {
    case idle
    case inFlight
    case error
    case permissionDenied
    case modelUnavailable
    case downloadingModel       // already exists (Apple Translation pack download)
    // NEW
    case downloadingASRModel(progress: Double)  // WhisperKit model download
    case correcting             // Foundation Models corrector pass in flight
}
```

---

## 2. Persisted entities (SwiftData)

A single new `@Model` joins `ConversationRecord`. Keeps the persistence story coherent with branch 003-fix-save-export's SwiftData introduction.

### 2.1 `SessionQualityRecord`

```swift
@Model
final class SessionQualityRecord {
    @Attribute(.unique) var id: UUID
    var startedAt: Date
    var endedAt: Date?
    var engineId: String                       // EngineId rawValue
    var accentGroupHint: String?               // AccentGroup rawValue, optional

    // Aggregates (snapshots over the session lifetime)
    var medianTokenConfidence: Double
    var p10TokenConfidence: Double             // worst-decile signal — predictive of "shaky" segments
    var revisionRatePerMinute: Double
    var avgWordsPerSecond: Double
    var fragmentationScore: Double

    // Latency in milliseconds, end-to-end (audio in → ES caption visible)
    var latencyP50Ms: Double
    var latencyP95Ms: Double

    // Defect counters
    var hallucinatedEntityCount: Int           // P0 if > 0
    var correctorInvocations: Int
    var correctorAcceptedCorrections: Int      // post-validation passes

    // Conversation linkage (optional — one conversation, many sessions if user restarted)
    var conversationId: UUID?

    init(...)
}
```

**Retention**: a maximum of N=50 most-recent records, oldest pruned at write. Privacy-safe by design — no transcript text is persisted in this model; only numeric quality signals.

### 2.2 `ConversationRecord` (existing, unchanged)

Already on branch 003. No schema change in this feature.

---

## 3. Evaluation-harness artifacts (file system, JSON)

These are **NOT** SwiftData — they're files the harness reads and writes outside the app sandbox.

### 3.1 `EvaluationCorpusManifest` (input to harness)

```json
{
  "name": "EdAcc-subset-v1",
  "license": "CC-BY-SA-4.0",
  "items": [
    {
      "id": "edacc_001_it_001",
      "audioPath": "audio/edacc/001_it_001.wav",
      "referenceTranscript": "I would like to book a table for two at seven o'clock.",
      "accentGroup": "italian",
      "speakerId": "s001",
      "durationSeconds": 4.8
    }
  ]
}
```

### 3.2 `EvaluationReport` (output)

```json
{
  "buildId": "005-accent-robust-asr@<sha>",
  "runDate": "2026-06-17T15:20:00Z",
  "engineId": "whisperKitTurbo",
  "correctorEnabled": true,
  "deviceClass": "iPhone17Pro",
  "corpus": "EdAcc-subset-v1",
  "totals": {
    "items": 412,
    "audioSeconds": 1843.2
  },
  "wer": {
    "aggregate": 0.117,
    "native": 0.061,
    "italian": 0.158,
    "indianSouthAsian": 0.172,
    "latino": 0.144,
    "other": 0.195
  },
  "cer": { "aggregate": 0.052, "...": "..." },
  "intelligibility": {
    "rater": "human-mturk-v1",
    "scale": "1-5",
    "italian": 4.2,
    "indianSouthAsian": 4.0,
    "latino": 4.1,
    "native": 4.7
  },
  "latency": {
    "p50Ms": 1850,
    "p95Ms": 3620,
    "p99Ms": 4810
  },
  "confidenceCalibration": {
    "spearmanRho": 0.68
  },
  "hallucinatedEntities": {
    "count": 0,
    "p0Defect": false
  },
  "correctorStats": {
    "invocations": 211,
    "acceptedEdits": 168,
    "rejectedEdits": 43
  }
}
```

### 3.3 `EvaluationDelta` (B vs A)

```json
{
  "baseline": "build-A-id",
  "candidate": "build-B-id",
  "verdict": "ACCEPTED" /* or "REJECTED_NATIVE_REGRESSION" or "REJECTED_HALLUCINATIONS" */,
  "wer": {
    "native": { "a": 0.061, "b": 0.058, "deltaAbs": -0.003, "gatePassed": true },
    "italian": { "a": 0.220, "b": 0.158, "deltaRel": -0.282, "gatePassed": true }
  },
  "gates": [
    { "name": "SC-001 ≥30% rel L2 reduction", "passed": true,  "value": -0.305 },
    { "name": "SC-002 ≤2pt absolute native regression", "passed": true, "value": -0.003 },
    { "name": "SC-004 zero hallucinated entities", "passed": true, "value": 0 },
    { "name": "SC-005 ρ ≥ 0.6", "passed": true, "value": 0.68 },
    { "name": "SC-006 p95 ≤ 4000 ms", "passed": true, "value": 3620 }
  ]
}
```

`verdict` is `ACCEPTED` only when **every** gate's `passed` is `true`. The harness exit code mirrors this — 0 if accepted, non-zero otherwise — so CI/scripted workflows can use it as a gate.

---

## 4. State transitions worth pinning down

### 4.1 Engine selection on session start

```
on startTranscription():
  if user.preference == .appleOnly        → use AppleSpeechAnalyzerEngine (or legacy on iOS<26)
  else if model.installState == .installed
       and device.supportsA17Pro          → use WhisperKitEngine
  else                                    → use AppleSpeechAnalyzerEngine
```

### 4.2 Per-segment corrector gate

```
on segment.isFinal && tokens.nonEmpty:
  if !device.supportsA17Pro               → emit segment as-is
  else if min(tokens.confidence) >= τ_skip → emit segment as-is (high-confidence → skip corrector)
  else:
    corrected = await corrector.correct(segment)
    if corrected contains any named entity NOT in segment → REJECT correction, emit original
    if corrected changes any numeral NOT in segment       → REJECT correction, emit original
    else                                                   → emit corrected
```

`τ_skip` is a tuned threshold; v1 default 0.85.

### 4.3 Confidence rendering rule (UI)

```
opacity_per_token = clamp(0.35 + 0.65 * token.confidence, 0.35, 1.0)
weight_per_token  = token.confidence >= 0.85 ? .semibold : .regular
```

Tokens with `confidence < 0.35` render at minimum opacity but are **never** hidden — honesty over silence (SC-010).

### 4.4 Translation segment uncertainty inheritance

The Spanish caption inherits the source English segment's `min(tokens.confidence)`. Apple Translation produces a single string; we attach the source min-confidence to it for rendering. The Spanish-side UI uses the same opacity rule.

---

## 5. Validation rules (what the harness asserts)

- `SpeechSegment.text` is whitespace-canonical (single spaces, trimmed).
- `SpeechSegment.confidence` is the mean of `tokens.confidence` when `tokens` is non-empty.
- `tokens.startTime` is monotonically non-decreasing across the segment.
- A `SpeechSegment` with `isFinal == true` and `tokens.isEmpty` is illegal except for the legacy engine.
- `SessionQualityRecord.hallucinatedEntityCount > 0` → the harness marks the report as `p0Defect: true` and the build delta's verdict is `REJECTED_HALLUCINATIONS`.
- No `SessionQualityRecord` may persist transcript text.
- `EvaluationReport.engineId` MUST match the engine actually used during the run (cross-checked from logs).

---

## 6. Files this introduces / changes

| Path | Action |
|---|---|
| `TranslatorApp/Domain/Entities/SpeechSegment.swift` | **Extend** with optional `tokens`, `source`, `isHypothesis` (backward-compatible) |
| `TranslatorApp/Domain/Entities/TranscriptToken.swift` | **New** |
| `TranslatorApp/Domain/Entities/EngineId.swift` | **New** |
| `TranslatorApp/Domain/Entities/AccentGroup.swift` | **New** |
| `TranslatorApp/Domain/Entities/EnginePreference.swift` | **New** |
| `TranslatorApp/Domain/Entities/ModelInstallState.swift` | **New** |
| `TranslatorApp/Domain/Entities/TranslatorState.swift` | **Modify** — add `downloadingASRModel`, `correcting` cases |
| `TranslatorApp/Data/Models/SessionQualityRecord.swift` | **New** SwiftData model |
| `TestSupport/Evaluation/EvaluationCorpusManifest.swift` | **New** Codable types |
| `TestSupport/Evaluation/EvaluationReport.swift` | **New** Codable types |
| `TestSupport/Evaluation/EvaluationDelta.swift` | **New** Codable types |

`TestSupport/` is a separate test target so the production binary doesn't ship corpus or evaluation types.
