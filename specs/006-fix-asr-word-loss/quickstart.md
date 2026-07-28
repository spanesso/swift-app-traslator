# Quickstart — Validating 006-fix-asr-word-loss

How to validate each phase on device and via the harness. Build in Xcode (⌘R) — this is a
pure Xcode project. Grant microphone + speech permissions at runtime.

## Phase 0 — Measurement (do this first)

1. **Wire the harness target** (005 T003): add `TranslatorAppEvaluationTests/` sources to a new
   XCTest target, add it to the `TranslatorApp` scheme.
2. **Confirm which engine runs**: launch the app, watch OSLog (subsystem
   `com.spanesso.TraslatorApp`, category `Container`) for the `[Container] engine=…` line.
   Expect `legacyAppleSFSpeech` on a device without a completed model install.
3. **Record baseline WER**: place a mini-corpus, run
   `xcodebuild test -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=iOS,name=<device>' -only-testing:TranslatorAppEvaluationTests/EdAccSubsetEvaluation`.
   Save the emitted JSON as the baseline. (Absent corpus → `XCTSkip`, still compiles.)

## Phase 1 — Classic engine (the symptom fix)

**H1 — no word loss on restart** (SC-001):
- Read a scripted passage with deliberate pauses every 10–15 s and a run past 60 s.
- Compare transcript to the script: **no** word immediately after a pause or the ~60 s
  restart may be missing.

**H2/H3 — accuracy** (SC-002):
- Read the same passage at normal volume, low volume, and ~1 m from the mic.
- Re-run the harness; WER for non-native + low-voice groups must improve vs the Phase-0
  baseline, with native WER not regressing beyond noise (SC-010).
- Confirm punctuation now appears in the EN transcript (precondition for the segmenter).

**H4 — metrics** : verify sessions are no longer flagged low-quality by default (OSLog
`Quality`); the 0.7 s segmenter timer should be used for clean speech, not 1.2 s.

**H5 — first words** : speak immediately on start with the Apple engine; the first word must
appear (no dropped opening segment).

**1-word utterances** (SC-003): say isolated "Yes" / "Okay"; they must appear.

**Confidence UI** (SC-006): confirm the opacity/indicator tracks the phrase it belongs to.

## Phase 2 — WhisperKit (device, A17 Pro)

- **W1**: select the WhisperKit engine; recording must start with **no** audio-format crash
  and the mic must not be silent.
- **W2/W3** (SC-007): dictate for ≥2 minutes; confirmed phrases appear translated in the
  Spanish panel **while still speaking** (not only on stop); no freeze/backlog.
- **W4** (SC-008): selecting the engine shows download/preparation progress; the model is
  preloaded before the first record; no tens-of-seconds stall on record.
- **W5**: read accented speech; legitimate windows are not dropped.

## Phase 3 — SpeechAnalyzer Tier 0 (iOS 26 device)

- **SC-009**: dictate continuously ≥5 minutes with pauses; **no** restarts and **no** word
  loss. Confirm OSLog shows the real SpeechAnalyzer engine selected as Tier 0, and that a
  non-supporting device falls back transparently.

## Regression guard (every phase)

Run the evaluation harness after each change; SC-010 requires no per-accent WER regression
beyond the evaluation noise margin vs the recorded baseline.
