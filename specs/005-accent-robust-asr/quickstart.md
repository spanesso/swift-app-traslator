# Quickstart — verifying feature 005

A "did the feature actually work" walkthrough. If you can run every step end-to-end and the numbers in step 3 satisfy the gates, the contract in `spec.md` is met.

## 0. Prerequisites

- Xcode 17+ on macOS 14+ (Sequoia or later)
- iOS 26 SDK
- Test device: one **A17 Pro+** iPhone (15 Pro / 16 / 17 family) AND one pre-A17 iPhone (older 14 or earlier) for fallback validation
- ~3 GB free space on each test device (WhisperKit large-v3-turbo compressed pack)
- Wi-Fi for the first-run model download
- Headphones recommended (loopback feedback when testing speakers)

## 1. Live transcription — golden path (A17 Pro+, after model download)

1. Build and run on the A17 Pro+ device on the `005-accent-robust-asr` branch.
2. First launch: dismiss permissions, accept the "Download enhanced accuracy model" consent sheet. Watch the download progress reach 100%. Background it; come back. The model should be installed.
3. Tap record. Speak an L2-accented English sentence — use one of the canned EdAcc samples below (read from the EdAcc dev set), or any heavily-accented speaker available.
4. **What to observe**:
   - English caption appears in the EN pane with **per-token opacity**: words the engine is confident in are bright; words it is uncertain about are faded. No badges, no `[unclear]` markers.
   - Spanish caption appears in the ES pane within ~2 seconds of the corresponding English caption.
   - The Spanish caption preserves named entities (people, places, brands, numerals) from the English — never introduces new ones.
5. Repeat with a native English speaker. The whole UI should be bright (high confidence) and snappy.

**Pass when**: both speakers produce captions that match what they said; no hallucinated entities in either direction; latency feels under 2.5 s median.

## 2. Live transcription — Lite mode (older device or declined download)

1. Build and run on the pre-A17 device, OR re-run on the A17 Pro+ device after declining the model download in Settings → Accuracy Model → Reset to Lite.
2. Tap record. Speak the same sentences as step 1.
3. **What to observe**:
   - English captions still appear with per-token opacity (iOS 26 `SpeechAnalyzer` exposes per-token confidence).
   - Spanish captions still appear.
   - On heavy L2 audio, expect more faded tokens and more revisions than in step 1 — this is **honest behavior**, not a bug. Tier 0 is weaker than Tier 1 by design.
   - No "Pro mode" UI is visible. The mode label, if any, says "Lite".

**Pass when**: the app works, captions appear, and the absence of the enhanced model is communicated clearly (not silently degraded).

## 3. Diagnostic harness — the numeric verdict

This is the gate. Builds that don't pass this don't ship.

```bash
# From repo root
xcodebuild test \
  -project TranslatorApp.xcodeproj \
  -scheme TranslatorApp \
  -destination 'platform=iOS,name=<your A17 Pro+ device>' \
  -only-testing:TranslatorAppEvaluationTests/EdAccSubsetEvaluation
```

The harness:
1. Loads `TestSupport/Evaluation/Corpora/edacc-subset-v1/manifest.json`.
2. Plays each audio file through the live pipeline (real-time, not faster — latency must be real).
3. Compares the engine output to the reference transcript per item.
4. Emits `evaluation-reports/005-accent-robust-asr@<sha>.json` with the full SC-001..SC-010 readout.

Open the JSON and check:

| Gate (from `spec.md`) | Field | Pass if |
|---|---|---|
| SC-001 | `wer.italian`, `wer.indianSouthAsian`, `wer.latino` vs baseline build | each ≥30 % relative reduction |
| SC-002 | `wer.native` vs baseline | regression ≤ 0.02 absolute |
| SC-004 | `hallucinatedEntities.count` | exactly `0` |
| SC-005 | `confidenceCalibration.spearmanRho` | ≥ 0.6 |
| SC-006 | `latency.p50Ms`, `latency.p95Ms` | ≤ 2500, ≤ 4000 |
| SC-009 | run twice, diff headline metrics | each ≤ 0.005 absolute |

If any gate fails, the harness exit code is non-zero and CI rejects the build. No silent acceptance.

## 4. B-vs-A comparison

After step 3 produces a report for build B, generate a delta vs the baseline (build A, on `main`):

```bash
xcrun --sdk macosx swift run evaluation-delta \
  --baseline evaluation-reports/baseline.json \
  --candidate evaluation-reports/005-accent-robust-asr@<sha>.json \
  --output evaluation-reports/delta.json
```

`delta.json` has a top-level `verdict` field. The only acceptable verdict is `accepted`.

## 5. Failure-injection smoke tests

These exist because SC-010 says "no silent failure". Each one must produce an explicit user-visible state within 3 s.

| Test | How to trigger | Expected outcome |
|---|---|---|
| Mic permission revoked mid-session | Settings → TranslatorApp → Microphone → Off (while recording) | Banner: "Microphone access revoked"; state machine enters `.permissionDenied`; recording stops |
| WhisperKit model file deleted | Run app on A17 Pro+, stop, delete `~/Library/Application Support/WhisperKit/large-v3-turbo-compressed/` via Files | Next session falls back to Tier 0 with a visible "Lite mode (model missing)" indicator; user can re-download |
| Network lost during model download | Toggle airplane mode while download is in flight | State machine enters `.failed(networkUnavailable)`; user can retry |
| Recording started before consent answered | Tap record while the consent sheet is still on screen | Tier 0 starts immediately; consent sheet stays; download begins on accept without interrupting the session |

## 6. Anti-hallucination guard

The corrector must never introduce a named entity or numeral. To verify:

```bash
xcodebuild test \
  -only-testing:TranslatorAppEvaluationTests/CorrectorAntiHallucination
```

This test feeds the corrector ~50 deliberately-broken transcripts (truncated, looped, low-confidence on critical spans) and asserts that:
- No output contains a proper noun absent from the input.
- No output contains a numeral absent from the input.
- All locked tokens (confidence ≥ 0.85 in input) are byte-identical in the output.

Any failure is a P0 defect. Do not ship.

## 7. UI smoke check (manual)

- Per-token opacity is visible to the naked eye in mixed-confidence sentences. (Bright next to faded, no fade applied uniformly.)
- Both panes have the same fade behavior for corresponding segments — confidence inherits.
- Lite mode is labeled "Lite", Pro mode is unlabeled (default).
- Save / Export still work (no regression in branch 003 features).

## 8. What to report when something is wrong

Attach to the bug:
1. The latest `evaluation-reports/*.json`.
2. The OS log filtered by subsystem `com.spanesso.TraslatorApp` for the session.
3. Device model and iOS version.
4. Engine that was active (visible in logs as `engineId=...`).
5. Whether the corrector ran (visible in logs as `[CORRECTOR]` lines).

Without (1) and (2), the team cannot reproduce.
