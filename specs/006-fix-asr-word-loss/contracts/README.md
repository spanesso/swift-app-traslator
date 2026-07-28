# Contracts — 006-fix-asr-word-loss

This corrective feature works behind the seams already established by feature 005. Most
contracts are **reused unchanged**; only two new/renamed pieces are introduced here.

## Reused unchanged (from `specs/005-accent-robust-asr/contracts/`)

- **`SpeechEngineProtocol.swift`** — the pluggable engine contract
  (`engineId`, `start(options:) → AsyncStream<SpeechSegment>`, `stop()`). Every engine touched
  by this feature (consolidated classic, WhisperKit, and the new real SpeechAnalyzer) conforms
  to it without changes. The audio-mode, request-config, ring-buffer, and streaming fixes are
  all *implementation-internal* to the adapters — the contract does not change.
- **`ModelDownloadCoordinatorProtocol.swift`** — still valid; W4 changes the *implementation*
  (unzip / `modelFolder` / preload-on-select / correct URL) and what flips `installed`, not the
  protocol surface. The state it emits (`ModelInstallState`) is unchanged.
- **`EvaluationHarnessProtocol.swift`** — unchanged; Phase 0 only wires the existing
  implementation into a real test target.
- **`TranscriptCorrectorProtocol.swift`** — untouched by this feature.

## New / changed in this feature

- **`AudioRingBuffer.swift`** — NEW. Carry-over ring buffer that closes the recognizer-restart
  audio gap (H1). Core of the Phase-1 word-loss fix.
- **`EmptySegmentFilter.swift`** — RENAME of `VADGate`. Clarifies that it filters empty **text**
  segments, not audio, and mandates a single application point (removing today's double-gating).

## Behavioral contracts asserted by the evaluation harness

- **SC-001**: 0 % word loss attributable to restarts on the scripted corpus.
- **SC-002 / SC-010**: WER improves for non-native + low-voice groups; native does not regress
  beyond the evaluation noise margin vs the Phase-0 baseline.
- **SC-003**: one-word utterances appear.
- **SC-007**: WhisperKit confirmed segments translate live within a 2-minute session, no freeze.
- **SC-009**: SpeechAnalyzer sustains a 5-minute continuous session with no restarts.
