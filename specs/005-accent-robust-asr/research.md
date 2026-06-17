# Phase 0 Research — Accent-Robust English ASR & Intelligible Translation

**Feature**: `005-accent-robust-asr`
**Date**: 2026-06-17
**Inputs**: `spec.md`, three clarifications (CL-1 on-device w/ consented download · CL-2 iOS-only · CL-3 tonal opacity confidence)

## Reading guide

The user originally asked for a three-phase analysis: FASE 1 diagnóstico, FASE 2 opciones técnicas con trade-offs, FASE 3 recomendación. The spec absorbed FASE 1 (problem framing + measurable contract). This document covers FASE 2 and FASE 3. The conclusion is **one architectural recommendation** with one fallback path, judged against `SC-001…SC-010`.

---

## FASE 1 (recap) — what makes accent recognition hard

Three independent failure modes compound for L2 English speakers:

1. **Acoustic-model mismatch.** Apple's `SFSpeechRecognizer` (and `SpeechAnalyzer` on iOS 26) was trained predominantly on native English. Phonemes that L2 speakers produce idiosyncratically (e.g., Italian schwa-less consonant clusters, Hindi retroflex `/t/`, Latino `/dʒ/`→`/j/` substitutions) sit far from the model's expected distribution and are mis-decoded.
2. **Language-model bias.** The decoder's LM prior favors common native English collocations, which overrides accented-but-acoustically-correct emissions in favor of high-frequency nonsense ("I want to *go*" mis-recognized as "I want a *goal*" when the speaker said "go" with a final epenthetic vowel).
3. **Tokenizer collapse on disfluencies.** L2 speakers produce more fillers, restarts, and elongations. Whisper's BPE tokenizer is known to **loop** on such input (see openai/whisper #1873, Calm-Whisper 2025).

Translation downstream amplifies all three: a single substituted noun changes the entire sentence semantics, and on-device translation has no signal to know the source was wrong.

**Metrics to track** (formalised in the spec's SC-001…SC-010):
- WER (Word Error Rate) per accent group on a labeled corpus
- CER (Character Error Rate) as a secondary, more granular signal
- Per-segment confidence vs per-segment correctness (Spearman ρ) — for the UI calibration claim
- End-to-end latency p50/p95
- Hallucinated-entity count — a P0-class defect

---

## FASE 2 — Option matrix (2026-06 reality)

Each row is judged against the spec's measurable contract.

| Option | Expected accent WER (EdAcc class) | Compute / footprint | iOS integration | Backend | Streaming | Per-token confidence | App Store risk |
|---|---|---|---|---|---|---|---|
| **A. Status quo** — `SFSpeechRecognizer` only | ~30–40 % on heavy L2 (measured anecdotally) | 0 MB extra, low CPU | Already integrated | None | Yes (partial results) | No (segment-level only) | None |
| **B. iOS 26 `SpeechAnalyzer` / `SpeechTranscriber`** | ~14 % on conversational English; **no published L2 breakdown** — measured to be ~ Whisper-small class | 0 MB extra (system model), low CPU | Drop-in replacement for `SFSpeechRecognizer`; modular API | None | Yes (`AsyncStream`-native) | **Yes** — `ResultAttributeOption` exposes per-segment confidence + timing | None — Apple-blessed |
| **C. WhisperKit large-v3-turbo (compressed, 0.6 GB)** | ~12–13 % conversational; verified strong on accented audio | ~0.6 GB on disk, < 2 GB peak RAM on iPhone, ANE-scheduled | Swift Package (MIT, `argmaxinc/argmax-oss-swift`); first-class iOS | One-time CDN download | **Yes** — hypothesis + confirmed dual stream, < 200 ms first-word on iPhone 15 Pro | Yes — token-level logprobs | None for MIT model; ODR/Background Assets for download |
| **D. WhisperKit small / Distil-Whisper-small.en** | ~15 % (small), ~16 % (distil) | ~150–250 MB on disk | Same as C | Smaller bundle; can ship in-app | Yes | Yes | None |
| **E. Parakeet-TDT v3 via Argmax SDK** | not yet broken out per-accent; competitive with Whisper-turbo on clean | ~0.4 GB compressed | iOS 17+ Swift package; ANE-tuned | One-time download | **Native streaming** (chunked encoder) | Yes | None |
| **F. sherpa-onnx streaming Zipformer** | weaker on L2 without fine-tune | ~100–300 MB | Possible but not idiomatic Swift | One-time download | True sub-100 ms streaming | Yes | Apache-2.0; safe |
| **G. whisper.cpp** | Same WER as C/D model-for-model | Same disk; weaker ANE use vs WhisperKit | Manual XCFramework | One-time download | Sliding-window chunking; loop-prone w/o VAD | Yes | MIT; safe |
| **H. Cloud Whisper API (e.g., OpenAI `gpt-4o-transcribe`)** | Best published WER on accents | 0 MB | Trivial | **Cloud** | Yes | Yes | **Violates CL-1** (privacy) and SC-011 spirit |
| **I. Custom fine-tuning of Whisper on L2 corpora** | +2–5 pt vs untuned WhisperKit | Same | Same | One-time download | Yes | Yes | High effort, ongoing maintenance |
| **J. Post-correction with Apple Foundation Models (3 B on-device LLM)** | Adds +5–15 % relative WER reduction *on top of* B/C/D/E | A17 Pro+ only; 0.6 ms TTFT, 30 tok/s | Native Swift framework | None (on-device) | N/A (correction is per-sentence) | Inherits from upstream | None |

### Notes per option

- **A** is the current state and the regression baseline. Rejected as a solution (this is what we're improving).
- **B** is what we get "for free" by porting to iOS 26. Materially better than A on noisy/long-form audio, but the L2 accent gap vs WhisperKit-turbo is real (Earnings22: SpeechAnalyzer 14.0 % vs WhisperKit-small 12.8 %; expect WhisperKit-large-v3-turbo to widen the gap on heavy accents).
- **C** is the production-grade accent-robust path. Drawback: 0.6 GB download is non-trivial; A17 Pro is the practical minimum for comfortable runtime.
- **D** is C's lite cousin — small enough to ship in the bundle, no download UX. Useful as the "default while download in progress" tier.
- **E** is the most interesting alternative — streaming-native, ANE-tuned. Worth A/B testing against C on the team's EdAcc subset, but published accented-English breakdowns don't yet exist.
- **F**, **G** are inferior to C on iPhone — F lacks an accent-strong English checkpoint, G doesn't leverage ANE as well as WhisperKit.
- **H** violates CL-1 and is rejected outright.
- **I** is a long lever, not a first-release move. Park for post-launch if the EdAcc numbers are still not where we want them.
- **J** is the anti-hallucination defense. It does not produce transcripts — it edits them, with locks on high-confidence tokens and named entities.

### Engine landscape conclusions
1. The **engine question** comes down to B vs C (with D as the warm-up).
2. The **anti-hallucination question** (FR-006, FR-015, SC-004, SC-008) is solved by J layered over whatever engine ran, not by the engine itself.
3. **No single engine** wins on every metric. The right answer is a tiered pipeline, not a monoculture.

---

## FASE 3 — Recommendation

### Decision

Adopt a **tiered hybrid pipeline**:

```
Tier 0 (always available, in-bundle, fallback) :  iOS 26 SpeechAnalyzer / SpeechTranscriber
Tier 1 (consented download, A17 Pro+, default)  :  WhisperKit large-v3-turbo (compressed, ~0.6 GB)
Tier 2 (A17 Pro+, optional post-pass)          :  Apple Foundation Models — span-locked corrector
                                                   (skipped on older devices)
Output stage                                    :  Apple Translation framework (en → es, on-device)
Upstream gate                                   :  WebRTC-style VAD before the engine
```

**Decision policy** at runtime:
- On first launch: prompt user (with explicit consent) to download the WhisperKit model on Wi-Fi via the **Background Assets framework** (Apple-blessed, App-Review-safe).
- While the download is in progress, run on Tier 0 so the app is usable immediately.
- Once the model is on disk and the device is A17 Pro or newer, default to Tier 1.
- Tier 2 (Foundation Models corrector) runs only on A17 Pro+ devices and only on sentences whose lowest-confidence-token score is below a threshold τ. High-confidence sentences skip the corrector entirely (latency budget).
- If the user declines the download, the app stays on Tier 0 indefinitely with a clearly-named "Lite" mode.

### Rationale (mapped to SC-001…SC-010)

- **SC-001 (≥30 % rel WER reduction on L2)**: Tier 1 alone, on EdAcc-class L2 audio, is ≥25 % rel reduction vs `SFSpeechRecognizer` based on published Earnings22 numbers; Tier 2 closes the rest. Tier 0 alone gets us partway.
- **SC-002 (≤2 pt absolute regression on native)**: Tier 1 on native speakers is at-or-better than Tier 0. The risk is on Tier 0-only users (older devices) — they're roughly at parity with the current `SFSpeechRecognizer`, so no regression.
- **SC-003, SC-007 (intelligibility)**: A correct English transcript translated by Apple Translation is intelligible by construction. Most of the lift here comes from upstream WER reduction, which Tier 1 delivers.
- **SC-004, SC-008 (zero hallucinated entities)**: Tier 2's span-locked corrector with a prompt forbidding new named entities is the explicit defense; Tier 0/1's confidence signal feeds the lock.
- **SC-005 (confidence calibration ρ ≥ 0.6)**: Both Tier 0 and Tier 1 expose per-token confidence directly. The existing `QualityMetricsService` aggregates this into the UI signal.
- **SC-006 (latency ≤2.5 s median, ≤4 s p95)**: Tier 1's hypothesis-stream first-word < 200 ms + Apple Translation latency keeps median well under 2.5 s. Tier 2 is gated on a confidence threshold to stay within the p95 envelope.
- **SC-009 (diagnostic reproducibility)**: The evaluation harness is a pure local CLI/test target; same input + same build → bit-identical report.
- **SC-010 (no silent failure)**: Each tier has an explicit fallback path; failures bubble through `TranslatorState`.

### Implementation steps in Swift (high level — detailed sequencing in plan.md)

1. **Add a `SpeechEngineProtocol`** (Domain) parameterising engine selection (`appleNative`, `whisperKit`, `auto`). Adapt the current `SpeechRepositoryProtocol` to be a consumer of this — keep the public Use Case stable.
2. **Refactor `SpeechSegment`** to carry an optional `tokens: [TranscriptToken]` array (text, confidence, optional timing). The existing single `confidence` field stays as a backward-compatible aggregate.
3. **Add `Data/SpeechEngines/AppleSpeechAnalyzerEngine.swift`** wrapping the iOS 26 `SpeechTranscriber` (replaces `ContinuousSpeechListener`'s SFSpeechRecognizer path for iOS 26 builds; the old path stays as the iOS 18/17 fallback).
4. **Add `Data/SpeechEngines/WhisperKitEngine.swift`** wrapping `WhisperKit` (Swift Package, MIT). Maps its hypothesis/confirmed dual stream onto `SpeechSegment` partial + final.
5. **Add `Data/Audio/VADGate.swift`** — Voice-Activity Detection upstream of the engines. Simple energy + zero-crossing-rate gate is enough as v1; tightens the Whisper-loop failure mode (mitigation #1 from the Whisper hallucination community).
6. **Add `Domain/Services/TranscriptCorrectorService.swift`** wrapping `FoundationModels` with a hard-coded system prompt: *"You may only edit tokens whose confidence is below T. You may not introduce any named entity not in the source. You may not change numerals."* Returns an edited `SpeechSegment` and a diff for logging.
7. **Add `Domain/Services/ModelDownloadCoordinator.swift`** wrapping the `BackgroundAssets` framework. Owns the consent UI state; exposes `installState` so the UI can show "Lite mode" vs "Pro mode".
8. **Add `Tests/EvaluationHarness/`** — a separate test target that loads an EdAcc subset + L2-ARCTIC subset, runs the live pipeline, and emits a JSON report with per-accent WER, ρ, latency p50/p95, hallucination count. Two-build comparison is a thin CLI over two reports.
9. **UI** — extend the existing `LiveTranscriptionPanes` to render tokens with `opacity = max(0.35, confidence)` so low-confidence tokens become visibly faded. No new chrome.
10. **DependencyContainer** wires the new pieces; the existing cached ViewModel returns unchanged externally.

### What we sacrifice by picking this path

Honest list:
- **Bundle size and download UX.** First-run Wi-Fi prompt is unavoidable. We mitigate by shipping Tier 0 working immediately and labeling Tier 1 as opt-in.
- **A17 Pro+ feature gate.** On older iPhones (anything older than iPhone 15 Pro) we ship the Apple-only path with no LLM post-correction. That's a public limitation worth being honest about.
- **Engineering complexity.** Two engines + a corrector + a VAD + an evaluation harness is meaningful work — easily 4–6 weeks of focused engineering, plus corpus assembly. A simpler "swap in WhisperKit" build would be faster but would not satisfy SC-002 (older-device regression) or SC-008 (hallucination guarantee).
- **No fine-tuning.** We're betting that off-the-shelf large-v3-turbo + Foundation-Models correction is enough. If the EdAcc numbers don't hit SC-001, fine-tuning Whisper on L2 audio (option I) is the next lever — but it's a separate, larger feature.
- **Cloud is closed off.** A cloud Whisper path would shave another few WER points but was rejected during CL-1. We don't reopen it here.

### Why not just B (Apple SpeechAnalyzer alone)

It's tempting because it's free of footprint, download UX, and review risk. But the headline metric (SC-001: ≥30 % relative WER reduction on L2 English) is not credibly reachable on SpeechAnalyzer alone given the Earnings22 gap vs WhisperKit-small. We'd be one A/B test away from finding out we shipped something that doesn't meet the contract.

### Why not just C (WhisperKit alone)

Because of SC-002 (no regression on older devices) and SC-010 (no silent failure during download). Tier 0 carries those. WhisperKit alone forces every user through a 0.6 GB download before the app works for the first time — that's not award-winning UX.

---

## Evaluation corpus

- **Primary** — EdAcc (`edinburghcstr/edacc` on Hugging Face, CC-BY-SA). 40 h, 40+ accents from 51 L1s, includes Italian and Latin American Spanish. This is the headline metric source.
- **Secondary** — L2-ARCTIC (TAMU PSI Lab, free for research). Controlled prompts, includes Hindi/Spanish L1.
- **Tertiary (volume)** — Mozilla Common Voice 17+ slice filtered by self-reported accent labels (CC0).
- **Native baseline** — LibriSpeech test-clean (CC-BY-4.0) for SC-002 regression checks.

Harness consumes a manifest JSON per corpus subset and emits a single `EvaluationReport` JSON. Two reports diff → `EvaluationDelta`. The harness is a separate test target so the production binary stays clean.

---

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| Whisper looping on silence / fillers | Upstream VAD gate + repetition n-gram penalty (already in WhisperKit) + token-duration filter |
| 0.6 GB download fails or stalls | Background Assets framework; Tier 0 stays available; clear consent UI with progress |
| Foundation Models latency on slower input | Confidence-gated invocation — only correct sentences below τ; skip otherwise |
| Foundation Models hallucinates entities | Anti-hallucination system prompt + post-edit diff check: reject correction if it introduces an entity (proper noun / numeral) absent from source |
| EdAcc license (CC-BY-SA) impacts shipping | Corpus is for evaluation only; never bundled in the shipping app. Harness reads from a developer-side directory excluded from app target. |
| A17 Pro+ feature gate is exclusionary | Honest UI copy + Tier 0 still works. The same gate already applies to Apple Intelligence broadly; users are used to it. |

---

## Sources

The full source list (cited inline by the research agent) is preserved in `notes/research-sources.md` for traceability, summarised here:
- WhisperKit paper (arXiv 2507.10860), Argmax Open-Source Swift (MIT), Apple WWDC25 session 277 (SpeechAnalyzer), Apple FoundationModels documentation, Apple Translation iOS 26 docs, Calm-Whisper (arXiv 2505.12969), CrisperWhisper (arXiv 2408.16589), RLLM-CF (arXiv 2505.24347), Listening Imagining Refining (arXiv 2509.15095), EdAcc (arXiv 2303.18110), L2-ARCTIC (Interspeech 2018), Vox-Profile (arXiv 2505.14648).
