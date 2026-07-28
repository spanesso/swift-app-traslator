# Phase 0 — Research & Decisions

**Feature**: 006-fix-asr-word-loss
**Date**: 2026-07-14
**Input**: `spec.md` + `INFORME-DIAGNOSTICO-ASR.md` + code inventory (current state)

This document resolves every open technical question by mapping each diagnostic
finding to a concrete, verified decision. Each entry: **Decision / Rationale /
Alternatives considered / Current-state anchor** (verified file:line).

---

## Ground truth: which engine runs today

- **Decision**: Treat `LegacySFSpeechEngine → ContinuousSpeechListener` as the primary
  target of Phase 1. Confirm per-device via OSLog before/after.
- **Rationale**: `DependencyContainer.swift:48–66` selects WhisperKit only when
  `DeviceCapabilities.supportsA17Pro && UserDefaults.bool("whsk.installed")`. The flag is
  set only after a completed ~600 MB download that, per the coordinator bug (W4), never
  produces a usable model. In practice most sessions fall through to `LegacySFSpeechEngine`
  (`DependencyContainer.swift:62`).
- **Current-state anchor**: `DependencyContainer.swift:48–66`; `BackgroundAssetsCoordinator.swift:92–106`.

---

## H1 — Audio lost on every recognition restart (primary cause of "se queda corta")

- **Decision**: Eliminate the restart audio gap using a **pre-primed carry-over ring buffer**:
  keep the audio engine + tap running (as today), but (a) create and start the *new*
  `SFSpeechAudioBufferRecognitionRequest` **before** ending the old one, and (b) maintain a
  rolling ring buffer (~1.5 s) of the most recent tap buffers that is replayed into the fresh
  request at restart so no spoken audio is dropped during the 150 ms sleep + recognizer warm-up.
- **Rationale**: The tap already runs continuously across restarts
  (`ContinuousSpeechListener.swift:126–157`), but between `endAudio()`/nil-request and the
  fresh request being ready, appended buffers hit a dead request and vanish. A short ring
  buffer prepended to the new request closes the gap without stopping capture (which the
  existing code deliberately avoids because stopping yields a stale zero-rate format on macOS).
- **Alternatives considered**:
  - *Double-request overlap only* (start new request first, no ring buffer): narrows but does
    not fully close the gap during recognizer warm-up (0.5–1 s). Rejected as insufficient.
  - *Never restart / raise the watchdog*: SF hard-caps ~60 s; not controllable. Rejected.
  - *Jump straight to SpeechAnalyzer (Phase 3)*: correct long-term fix but device-gated and
    larger; kept as US5, not a Phase-1 dependency.
- **Current-state anchor**: `ContinuousSpeechListener.swift:126–157` (restart), `:114–122`
  (65 s watchdog), `:98–104` (restart trigger on `isFinal||error`).
- **Note**: `ContinuousSpeechListener` sets its continuation **synchronously** in `start()`
  (`:47`) — H5 does **not** apply to it. H5 is exclusive to `AppleSpeechAnalyzerEngine`.

---

## H2 — `.measurement` audio mode degrades accented / quiet / distant speech

- **Decision**: Change `AVAudioSession` mode from `.measurement` to **`.spokenAudio`**
  (fall back to `.default` if unavailable), keeping category `.record` and dropping
  `.duckOthers` only if it interferes; validate against the corpus before/after.
- **Rationale**: `.measurement` disables system AGC + noise reduction — the opposite of what
  low-SNR accented/quiet/distant speech needs. `.spokenAudio` (or `.default`) restores the
  system signal chain tuned for voice. This is a one-line change with measurable upside.
- **Alternatives considered**: `.voiceChat`/`.videoChat` (adds echo cancellation intended for
  duplex calls — unnecessary and can distort a single-ended dictation path). Rejected.
- **Current-state anchor**: `ContinuousSpeechListener.swift:55–59`; identical config in
  `AppleSpeechAnalyzerEngine.swift` (`.record`/`.measurement`/`.duckOthers`).

---

## H3 — Recognition request left unconfigured

- **Decision**: On every `SFSpeechAudioBufferRecognitionRequest`, set
  `taskHint = .dictation`, `addsPunctuation = true`, and pass a domain
  `contextualStrings` list (sourced from a small configurable vocabulary constant).
- **Rationale**: `addsPunctuation` is a precondition for the segmenter, which depends on
  punctuation that "casi nunca llega" today; `.dictation` biases the recognizer for
  continuous speech; `contextualStrings` cheaply improves domain-term recall. All three are
  free precision on the engine that runs today.
- **Alternatives considered**: On-device-only forcing via `requiresOnDeviceRecognition` —
  orthogonal to accuracy and can *reduce* quality on some locales; leave as-is unless the
  corpus shows benefit.
- **Current-state anchor**: request built at `ContinuousSpeechListener.swift:62–107`
  (`shouldReportPartialResults = true` only); no hint/punctuation/context set.

---

## H4 — Partial-result confidence (0.0) contaminates quality metrics

- **Decision**: Feed **only final-result** (or non-zero) confidence into
  `QualityMetricsService.recordConfidence`; ignore confidence from partial segments.
- **Rationale**: `SFSpeechRecognizer` reports 0.0 confidence on partials. Averaging those in
  drags `avgConfidence` below the `< 0.6` threshold, so `isLowQualitySpeech()` returns true
  almost always and the segmenter runs the long 1.2 s timer, inflating perceived latency with
  no real cause.
- **Alternatives considered**: Lower the threshold — treats the symptom, not the cause, and
  weakens genuine low-quality detection. Rejected.
- **Current-state anchor**: threshold `QualityMetricsService.swift:112`; confidence feed
  `:56–60`, averaged in `getCurrentMetrics()` `:99`.

---

## H5 — Continuation race in `AppleSpeechAnalyzerEngine.start()` drops first segments

- **Decision**: Assign the `AsyncStream` continuation **synchronously** inside the
  `AsyncStream { cont in ... }` builder (mirror `ContinuousSpeechListener.swift:47`), then
  start recognition; do not defer via a detached `Task { await setContinuation(cont) }`.
- **Rationale**: Today `configureAndStart()` and the first recognizer callbacks can fire
  before the async `setContinuation` runs, so early `continuation?.yield` calls no-op and the
  first words are lost.
- **Alternatives considered**: Buffer pre-continuation segments in a temp array — more code
  for the same effect the synchronous assignment achieves for free. Rejected.
- **Current-state anchor**: `AppleSpeechAnalyzerEngine.swift:37–39`.

---

## Engine consolidation (`ContinuousSpeechListener` vs `AppleSpeechAnalyzerEngine`)

- **Decision**: Keep a **single** classic-`SFSpeechRecognizer` implementation behind
  `SpeechEngineProtocol` and delete the duplicate. Retain the one with the correct
  continuation lifecycle and add token-detail support to it; route `LegacySFSpeechEngine` and
  `.appleSpeechAnalyzer` selection to the same underlying actor until Phase 3 introduces the
  real `SpeechAnalyzer`.
- **Rationale**: The two are "casi el mismo motor duplicado"; each carries H1, and fixing H1
  twice invites divergence. `ContinuousSpeechListener` has the safe continuation and a
  watchdog; `AppleSpeechAnalyzerEngine` has token mapping. Merge the strengths.
- **Alternatives considered**: Leave both and fix in parallel — rejected (double maintenance,
  regression risk). Full deletion of the legacy path now — rejected until Phase 3 lands, since
  it is the only engine that runs on non-A17 devices / iOS < the SpeechAnalyzer baseline.
- **Constraint**: `swift-app-traslator/CLAUDE.md` "Max 250 lines per Swift file" — the merged
  engine must stay under budget or split (`+Restart.swift`).

---

## W1 — WhisperKit tap format invalid (blocking)

- **Decision**: Install the tap at the input node's **native hardware format** and convert to
  16 kHz mono Float32 with an `AVAudioConverter` before appending to Whisper's buffer.
- **Rationale**: `AVAudioEngine` requires the tap format to match the node's output sample
  rate (48 kHz on device). Requesting 16 kHz directly throws
  `IsFormatSampleRateAndChannelCountValid` / silences capture — evidence the engine has never
  run successfully on device.
- **Alternatives considered**: Reconfigure the hardware to 16 kHz — not reliably supported and
  breaks other consumers. Rejected.
- **Current-state anchor**: `WhisperKitEngine.swift:75–84` (explicit 16 kHz mono tap format).

---

## W2 / W3 — Unbounded buffer, full re-transcription, no live translation

- **Decision**: Replace the hand-rolled 2 s loop with WhisperKit's **`AudioStreamTranscriber`**
  (sliding windows, confirmed segments, `chunkingStrategy: .vad`). Emit its **confirmed**
  segments as `isFinal: true` (not `isHypothesis`) so they flow through the use case →
  segmenter → translation in real time. Bound any residual buffer.
- **Rationale**: Today `audioBuffer` grows from session start and is re-transcribed whole every
  2 s (`WhisperKitEngine.swift:101–117`, cleared only on final flush `:153`); by 30–60 s each
  pass exceeds the 2 s window and the loop falls irrecoverably behind ("se congela"). And every
  mid-session emit is `isHypothesis:true` (`:150`), which the use case excludes
  (`TranscribeAudioUseCase.swift:48`), so the Spanish panel gets nothing until stop.
  `AudioStreamTranscriber` implements LocalAgreement streaming and solves W2, W3, W6 together.
- **Alternatives considered**: Keep the loop but window a fixed tail — still no confirmed-segment
  semantics and no live translation. Rejected.
- **Downstream**: `NLPSegmenterService.pendingHypothesis` (`:28`, handling `:56–61`) becomes
  reachable/consumable or is removed as dead code once confirmed segments are emitted as final.
- **Current-state anchor**: `WhisperKitEngine.swift:101–117`, `:150`, `:153`;
  `TranscribeAudioUseCase.swift:48`.

---

## W4 — Model download disconnected from the engine

- **Decision**: Unify model management. Preferred path: use **WhisperKit's built-in download**
  with a progress callback wired to the existing `ModelInstallState` UI, **preloaded when the
  engine is selected**, never on record. If the `BackgroundAssets` path is retained instead,
  **unzip** the artifact and pass `modelFolder` to `WhisperKitConfig` so the downloaded model
  is actually used; correct the download URL to the real `whisperkit-coreml` layout
  (folders of `.mlmodelc`, not a single `.mlpackage.zip`). Only set `whsk.installed = true`
  once the model is verified loadable. **Pin the SPM package to a released version** (not `main`).
- **Rationale**: Today `BackgroundAssetsCoordinator` stores an un-extracted `.zip` and flips
  `whsk.installed` (`:92–106`), while `WhisperKitEngine` inits `WhisperKit(config)` with no
  `modelFolder` (`:34–42`) and downloads its own copy from Hugging Face **on record**, then
  loads for tens of seconds with no UI feedback. The downloaded artifact is dead weight.
- **Alternatives considered**: Keep both download paths — guarantees the current desync.
  Rejected.
- **Current-state anchor**: `BackgroundAssetsCoordinator.swift:92–106` (no unzip; single
  `.mlpackage.zip` URL); `WhisperKitEngine.swift:34–42` (no `modelFolder`); WhisperKit SPM
  pinned to `branch main` (`project.pbxproj:615–623`, `Package.resolved`).

---

## W5 — `firstTokenLogProbThreshold` discards accented speech

- **Decision**: Remove or relax `firstTokenLogProbThreshold` (from `-1.5` toward a more
  permissive value or `nil`), then re-validate on the accented corpus so windows of legitimate
  accented speech are not suppressed.
- **Rationale**: A strict first-token threshold drops exactly the low-first-token-probability
  windows that accented speech produces → lost words.
- **Alternatives considered**: Compensate downstream — cannot recover audio already discarded
  by the decoder. Rejected.
- **Current-state anchor**: `WhisperKitEngine.swift:126` (`DecodingOptions(... firstTokenLogProbThreshold: -1.5)`).

---

## W6 — Windowing without overlap/context

- **Decision**: Subsumed by adopting `AudioStreamTranscriber` (LocalAgreement + prompt context),
  which carries overlap and previous-text context across windows.
- **Rationale**: Avoids re-implementing what WhisperKit already ships.
- **Current-state anchor**: n/a (behavior emerges from the W2/W3 decision).

---

## Model-size question (`large-v3-turbo` vs `small`/`distil`)

- **Decision**: Keep the compressed `large-v3-turbo` as default, but add `small`/`distil` as
  harness-comparable candidates and let the WER-vs-latency numbers decide. Do **not** block
  Phase 1/Phase 2 landing on this evaluation.
- **Rationale**: On iPhone only the quantized large variant is currently reasonable, but the
  spec (SC-002/SC-010) requires numeric justification; the harness makes this a measurement,
  not a guess. `EngineId.whisperKitSmall` already exists but is unused.
- **Current-state anchor**: `EngineId` enum (`whisperKitSmall` defined, unused).

---

## Fase 0 — Evaluation harness not wired into a test target

- **Decision**: Wire the existing `TranslatorAppEvaluationTests/` sources into a real Xcode
  test target (T003 from 005), add it to the `TranslatorApp` scheme, and record a **baseline
  WER per accent group** before any Phase-1 change. Add a one-line OSLog at container init
  that states the selected engine unambiguously (T-diagnostic).
- **Rationale**: The harness code exists (`EvaluationHarness.swift`, `WERCalculator.swift`, …)
  but the folder is a member of **no** target (project has only `TranslatorApp`,
  `TranslatorAppTests`, `TranslatorAppUITests`), so `xcodebuild test` cannot run it. Without a
  baseline every improvement is anecdotal and regressions are invisible (SC-004, SC-010).
- **Alternatives considered**: Manual before/after listening tests — not reproducible. Rejected.
- **Current-state anchor**: `TranslatorAppEvaluationTests/` not referenced in `project.pbxproj`;
  005 tasks T001/T003/T004 remain unchecked.

---

## Fase 3 — iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` as Tier 0

- **Decision**: Implement a **real** `SpeechAnalyzer`/`SpeechTranscriber` engine behind
  `SpeechEngineProtocol` and select it as Tier 0 on supported devices via
  `DeviceCapabilities.supportsEnhancedFrameworks`; fall back transparently to the consolidated
  classic engine elsewhere.
- **Rationale**: `AppleSpeechAnalyzerEngine` uses classic `SFSpeechRecognizer` despite its name.
  The real API removes the ~60 s cap and restart cycle (root of H1) and improves long-form —
  likely more value than the whole WhisperKit effort for most cases. Deployment target is
  already `26.1`, so the API is available.
- **Alternatives considered**: Skip and rely on the H1 ring-buffer fix forever — leaves the
  restart machinery and its edge cases in place. Rejected as the long-term posture.
- **Current-state anchor**: `AppleSpeechAnalyzerEngine.swift:17–19,66,79` (classic API);
  `DeviceCapabilities.swift:31–35` (`supportsEnhancedFrameworks`); `IPHONEOS_DEPLOYMENT_TARGET = 26.1`.

---

## Cross-cutting findings

### VADGate is text-empty filtering, not acoustic VAD (+ double gating)
- **Decision**: Rename/clarify `VADGate` as `EmptySegmentFilter` (its true role), and remove the
  **duplicate** application (it runs both inside `WhisperKitEngine` and again in
  `SpeechRepository`). Real energy VAD, if needed, comes from WhisperKit's `chunkingStrategy: .vad`.
- **Rationale**: The name overpromises; it filters empty **text** segments within a 500 ms
  window, not audio. Double-gating the WhisperKit path is redundant.
- **Current-state anchor**: `VADGate.swift` (42 lines); applied at `WhisperKitEngine.swift:51`
  **and** `SpeechRepository.swift:27`.

### Confidence indicator bound to the wrong phrase
- **Decision**: Carry confidence **on the segment/phrase** through to translation instead of
  reading a mutable `latestSegmentConfidence` at emit time, so the UI opacity reflects the
  phrase it represents.
- **Rationale**: `latestSegmentConfidence` (`TranscriptionViewModel.swift:65`, updated `:164`)
  is stamped onto a `TranslationRequest` at `:178` — a race between the latest raw segment and
  the phrase being emitted; they need not correspond.
- **Current-state anchor**: `TranscriptionViewModel.swift:65,164,178`.

### One-word utterances suppressed
- **Decision**: Allow ≤1-word segments to emit when they represent a complete utterance
  (e.g. terminator-followed or stability-flushed), not only when `isFinal`.
- **Rationale**: `NLPSegmenterService.swift:49–54` drops `wordCount < 2 && !isFinal`; with
  engines that rarely emit finals, "Yes"/"Okay" disappear (SC-003).
- **Current-state anchor**: `NLPSegmenterService.swift:49–54`; `minShortPhraseWords` in
  `emitIfViable` `:151`.

---

## Sequencing & risk summary

| Phase | Findings | Device dependency | Risk | Gate |
|---|---|---|---|---|
| 0 | harness/baseline, engine-log | none | low | must precede validation of 1–3 |
| 1 (🔴) | H1, H2, H3, H4, H5, consolidation, cross-cutting | none (all iPhones) | low–medium | WER must not regress vs baseline |
| 2 (🟡) | W1–W6, model mgmt, SPM pin | A17 Pro + model | high | live ES output; no freeze at 2 min |
| 3 (🟠) | SpeechAnalyzer Tier 0 | iOS 26 SpeechAnalyzer | medium | 5 min continuous, no restarts |

All decisions respect the de-facto constitution (`CLAUDE.md`): Clean Architecture boundaries,
Domain purity, ViewModels owned by the composition root, capture/detection off the MainActor,
Swift-6 strict concurrency without `@unchecked Sendable`, no new third-party dependencies
beyond the already-present WhisperKit, and ≤250 lines per Swift file.
