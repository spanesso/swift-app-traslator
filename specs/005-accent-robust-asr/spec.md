# Feature Specification: Accent-Robust English Speech Recognition & Intelligible Translation

**Feature Branch**: `005-accent-robust-asr`
**Created**: 2026-06-17
**Status**: Draft
**Input**: User description: "Speech detection is not fluid — Italian, Indian, and Latino speakers attempting English fail. Translations become incoherent because malformed source phrases propagate downstream. Make the app award-winning."

## Problem Statement

The current product (English → Spanish live translator) was designed against the implicit assumption of native or near-native English input. In real-world use, a large fraction of users speaking English to the app are L2 speakers (Italian, Indian/South-Asian, Spanish-influenced/"Latino", and others). Their accents stress the underlying speech engine in ways that produce two visible symptoms:

1. **Inaccurate transcription** — phonemes misclassified, words substituted, words dropped.
2. **Incoherent translation** — because the Spanish output is downstream of the English transcript, errors compound. A user often sees a translation that is grammatically valid Spanish but semantically nonsense.

These are not two bugs. They are one bug (poor upstream recognition for non-native speech) observed in two places. The current pipeline has no mechanism to (a) detect that upstream quality has collapsed, (b) repair partial or malformed transcripts before translation, or (c) measure whether any change actually helps.

This feature defines the user-facing quality contract the app must satisfy to be defensible as an "award-winning" live translation product for international/non-native English speakers, and the measurable signals by which we will judge whether we have met it.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — L2 English speaker is understood and translated coherently (Priority: P1)

A user with a noticeable non-native English accent (Italian, Indian, or Spanish-influenced) speaks naturally into the app. They see English captions that match what they said, and a Spanish translation that conveys the same meaning. If a phrase is ambiguous, the app does not invent words — it waits, hedges, or marks low confidence rather than emitting fluent nonsense.

**Why this priority**: This is the core promise. Without it, the app is unusable for its real audience. Every other story depends on this working.

**Independent Test**: Play a held-out recording of an L2 speaker (Italian/Indian/Latino) reading a 50-sentence script. Measure (a) the English transcript word-error rate vs the script, and (b) human-rated intelligibility of the Spanish translation on a 1–5 scale. The story passes when both metrics meet the targets in *Success Criteria*.

**Acceptance Scenarios**:

1. **Given** an Italian-accented speaker says *"I would like to book a table for two at seven o'clock"*, **When** the speaker finishes the phrase, **Then** the English caption matches the spoken sentence within ≤1 substitution and the Spanish translation conveys the same booking intent (table, two people, 7 PM).
2. **Given** an Indian-accented speaker says *"Could you please send me the report by tomorrow morning?"*, **When** the phrase completes, **Then** both fields (English, Spanish) preserve the request, the deadline, and the politeness register.
3. **Given** a Spanish-L1 speaker says *"My flight is delayed and I'm going to arrive late"* with strong Latino phonology, **When** the phrase completes, **Then** the Spanish translation is recognizable as a faithful paraphrase, not a literal mistranscription of the English error.
4. **Given** the engine genuinely cannot determine a word, **When** it emits the segment, **Then** the user sees an explicit uncertainty signal (e.g., greyed token, "[unclear]" marker, or a confidence indicator) rather than a confident wrong word.

---

### User Story 2 — User sees and trusts the quality signal (Priority: P2)

The app surfaces, in real time, how confident it is. A user with a heavier accent sees that the system is struggling and can adapt (speak slower, rephrase, move closer to the mic). A confident user gets clean captions and is not distracted by warnings. The quality signal is a first-class part of the UI, not buried in logs.

**Why this priority**: Even the best ASR will fail sometimes. A product that admits uncertainty is trusted; one that hides it is not. This story converts an honest limitation into a usability feature.

**Independent Test**: With identical audio input, verify the per-segment confidence shown to the user correlates with measured per-segment error rate (Spearman ρ ≥ 0.6 on the held-out test set). Verify users in a quick (n≥5) usability check correctly identify which captions are "trustworthy" vs "shaky".

**Acceptance Scenarios**:

1. **Given** clean native-speaker audio, **When** captions appear, **Then** the confidence indicator stays in its "high" state for ≥95% of segments.
2. **Given** a strongly-accented speaker plus background noise, **When** captions appear, **Then** at least some segments are visibly marked "low confidence" and the user can distinguish them at a glance.
3. **Given** a low-confidence English segment, **When** the Spanish pane updates, **Then** the corresponding Spanish segment is also marked uncertain (the uncertainty propagates, it is not silently dropped).

---

### User Story 3 — Diagnostic baseline and regression protection (Priority: P2)

Before changing anything, the team can quantify *how bad* the current pipeline is on non-native input, and *how much* any future change has helped or hurt. The app records (or supports replaying) a standardized test corpus and reports the headline metrics. A change that helps L2 accents but degrades native input by more than a defined threshold is automatically flagged.

**Why this priority**: Without this, every "improvement" is anecdotal. Award-winning products are defended by numbers, not vibes. This also protects against the common failure mode where a new ASR model helps the loud problem (L2 accents) but quietly degrades the silent one (native speakers, short utterances, technical vocabulary).

**Independent Test**: Run the diagnostic harness against the current build → it emits a numeric report (WER per accent group, latency, intelligibility score, native-speaker regression delta). Run it again against a candidate build → the report shows the delta. The story passes when both runs complete unattended and the report is reproducible.

**Acceptance Scenarios**:

1. **Given** the diagnostic test corpus, **When** the harness runs against build A, **Then** it produces a report with WER broken down by accent group (native, Italian, Indian, Latino, other) and end-to-end latency percentiles.
2. **Given** a candidate build B, **When** the harness runs again, **Then** the report shows a per-group delta vs build A and flags any accent group that regressed beyond the defined tolerance.
3. **Given** a build that improves L2 accents but degrades native input by more than the tolerance, **When** the report is generated, **Then** it visibly fails the "no native regression" gate and is not silently accepted.

---

### User Story 4 — Translation degrades gracefully on bad source (Priority: P3)

When the English transcript is genuinely garbled (the speaker mumbled, signal was lost, vocabulary was out-of-domain), the Spanish pane does not produce confident-sounding nonsense. It either (a) holds output until the source stabilizes, (b) emits a clearly-marked partial, or (c) skips the segment and continues, depending on the configured behavior. The translation never invents content that the English transcript did not assert.

**Why this priority**: This converts an upstream failure into a controllable downstream behavior. P3 because it is partially handled by US1 + US2 — but it deserves its own story because there are translation-side decisions (hold vs hedge vs skip) that the upstream engine cannot make alone.

**Independent Test**: Inject a corpus of deliberately broken English transcripts (truncated, repeated tokens, hallucinated words) and verify the Spanish output for each one matches the agreed degradation behavior (no confident nonsense, visible uncertainty, no invented entities).

**Acceptance Scenarios**:

1. **Given** an English transcript flagged low-confidence, **When** translation runs, **Then** the Spanish output is either marked uncertain or held until confidence improves.
2. **Given** an English transcript containing a repeated/looping token (a known ASR failure mode), **When** translation runs, **Then** the Spanish output does not amplify the loop and does not invent surrounding context.
3. **Given** an empty or near-empty English segment, **When** translation runs, **Then** no Spanish output is emitted (no hallucinated translation of silence).

---

### Edge Cases

- **Code-switching** — speaker mixes English and Spanish (or English and Hindi) in the same sentence. Behavior must be defined: ignore non-EN tokens? Pass them through?
- **Very short utterances** (≤2 words) where there is no context to disambiguate. The engine must not over-commit; the translation must not pad.
- **Long monologues without sentence-final punctuation cues** — current segmenter relies on silence and clause markers; L2 speakers often have unusual prosody and may not produce the expected silence gaps.
- **Domain-specific vocabulary** — proper nouns, brand names, technical terms. These are often where confidence collapses for any speaker; double-collapse for L2.
- **Background noise + accent** combined. Each is hard alone; together they are the worst case and should be the upper bound on the test corpus.
- **Speaker change mid-session** — a native speaker hands the mic to an L2 speaker. The quality signal must respond within a small number of segments, not lag the change.
- **Mic distance / level variation** — L2 speakers often speak more quietly when uncertain, which compounds the recognition problem.
- **First-run state** — if a heavier model or accent profile needs to be prepared, the user must see honest progress, not a silent stall.

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST produce English transcriptions for non-native speakers whose accent matches one of the prioritized accent groups (Italian, Indian/South-Asian, Spanish-influenced/Latino) at a measurably higher accuracy than the current shipping pipeline on the same test corpus.
- **FR-002**: The system MUST NOT regress transcription accuracy for native English speakers beyond a defined tolerance (see *Success Criteria*).
- **FR-003**: The system MUST expose a per-segment confidence signal to the UI, distinguishable by the user at a glance, with at least three levels (e.g., high / medium / low) or a continuous indicator with a comparable resolution.
- **FR-004**: The system MUST propagate uncertainty from English to Spanish. A low-confidence English segment MUST NOT produce a high-confidence-styled Spanish segment.
- **FR-005**: The system MUST NOT emit a Spanish translation for an English segment that is empty, silence-only, or below a defined minimum-quality threshold.
- **FR-006**: The system MUST detect and refuse to amplify common ASR failure modes (looping tokens, hallucinated repetitions) before they reach the translation layer.
- **FR-007**: The system MUST record per-session quality metrics (word-error rate proxy, segment confidence distribution, latency percentiles, revision rate) and make them inspectable for diagnostic purposes.
- **FR-008**: The system MUST support a reproducible offline evaluation harness that runs a held-out audio corpus through the live pipeline and emits a numeric report broken down by accent group.
- **FR-009**: The evaluation harness MUST produce a comparison report between two builds (A vs B) and visibly flag any accent group that regressed beyond tolerance — including the native-speaker group.
- **FR-010**: End-to-end latency (audio captured → Spanish caption visible) MUST stay within the defined target percentile envelope (see *Success Criteria*). No quality improvement is accepted if it pushes latency outside the envelope.
- **FR-011**: The system MUST preserve the existing offline-capable behavior for any code path declared on the offline tier (see *Assumptions* and *Clarifications*). If a heavier or networked path is introduced, the user MUST be informed and MUST consent.
- **FR-012**: The system MUST handle pipeline failure (engine crash, model unavailable, network loss for any networked path) by surfacing a clear state to the user, not by silently emitting empty or stale captions.
- **FR-013**: The system MUST allow the user to indicate (explicitly or via observable behavior over time) a preferred accent profile, and MUST use that information to bias the engine when supported. Absence of any signal MUST default to a sensible general-purpose configuration.
- **FR-014**: The system MUST persist diagnostic session records locally (consistent with the existing SwiftData store on the current branch) so quality regressions can be investigated after the fact.
- **FR-015**: The user-facing Spanish output MUST NOT introduce named entities (people, places, brands, numbers) that did not appear in the English transcript. Hallucinated entities are a P0-class defect for this feature.

### Key Entities *(include if feature involves data)*

- **Transcription Segment** — a unit of recognized speech with text, timing, and an associated confidence value; carries quality metadata downstream to the translation layer.
- **Translation Segment** — the Spanish counterpart of a transcription segment, with its own confidence inherited from (and never higher than) the English source segment.
- **Session Quality Record** — per-session aggregate: counts and distribution of segment confidences, latency percentiles, revision rate, perceived accent group (if inferred), persisted locally for inspection.
- **Accent Group** — a coarse label used for evaluation and (optionally) for runtime biasing: at minimum {native, italian, indian, latino, other}. Used by the harness to break down metrics; not exposed as a user-pickable taxonomy unless required by US2.
- **Evaluation Corpus** — a held-out collection of audio + reference transcripts, labeled by accent group, used by the harness in FR-008 / FR-009. Lives outside the shipping app bundle.
- **Evaluation Report** — the artifact produced by the harness; the unit of truth for "is build B better than build A".

---

## Success Criteria *(mandatory)*

All thresholds below are user-facing quality targets. They are measurable without referencing any specific framework or model.

### Measurable Outcomes

- **SC-001** *(headline accuracy)* — On the held-out non-native test corpus, English transcription word-error rate is **reduced by at least 30% (relative)** versus the current shipping pipeline, measured per accent group and aggregated.
- **SC-002** *(no native regression)* — On the native-speaker subset of the same corpus, transcription word-error rate **degrades by no more than 2 percentage points (absolute)** versus the current pipeline. A larger regression fails the gate.
- **SC-003** *(translation intelligibility)* — Human raters judging Spanish translations on a 1–5 intelligibility scale rate **≥80% of non-native-source segments at 4 or higher**, versus the current baseline measured on the same corpus.
- **SC-004** *(no hallucinated entities)* — Across the full evaluation corpus, **zero translation segments** contain a named entity (person, place, brand, number) absent from the corresponding English transcript. Any occurrence is a P0 defect.
- **SC-005** *(confidence calibration)* — Per-segment confidence correlates with per-segment correctness at **Spearman ρ ≥ 0.6** on the held-out set, so the UI indicator is informative rather than decorative.
- **SC-006** *(latency envelope)* — Median end-to-end latency (audio in → Spanish caption visible) stays **≤ 2.5 seconds**; p95 stays **≤ 4.0 seconds**, on the reference iPhone device class. These targets are aggressive for an on-device pipeline running a heavier model on iPhone hardware and MUST be re-confirmed on the chosen reference device during the plan phase; if confirmed infeasible, the targets are revisited with the user before implementation, not silently relaxed.
- **SC-007** *(perceived quality)* — In a small structured usability test (n ≥ 5 L2 speakers per priority accent group), **≥ 80% of participants** report that the Spanish output "conveyed what I meant" for ≥ 80% of their utterances.
- **SC-008** *(graceful degradation)* — On the deliberately-broken-transcript corpus (US4), the Spanish output **never emits a confident-styled segment for a low-confidence source segment**, and **never invents a named entity**.
- **SC-009** *(diagnostic reproducibility)* — Two independent runs of the harness against the same build produce reports whose headline metrics agree within **±0.5 percentage points absolute**.
- **SC-010** *(no silent failure)* — Across all failure-injection tests (engine crash, model missing, mic permission revoked mid-session, network loss for any networked tier), the user sees an explicit state change within **≤ 3 seconds** of the failure; no test produces a silent stall.

---

## Assumptions

- **Reference device class** is a modern iPhone running a recent iOS (see CL-2). Latency, footprint, and battery are measured against that device class. The current macOS development hardware is used for engineering and harness work but is not the shipping target.
- **Reference accent set for v1** is {Italian, Indian/South-Asian, Spanish-influenced/"Latino"} as named in the request, plus {native English} as the regression baseline. "Other" non-native accents are best-effort, not in the headline metrics.
- **Source/target language pair** stays English → Spanish for this feature. Multi-language support is out of scope.
- **Evaluation corpus** does not yet exist and must be assembled (or sourced) as part of this work. The harness depends on it, so corpus assembly is part of the deliverable.
- **Runtime offline guarantee** applies to every transcription and translation code path. Network is allowed only at install/first-run for a one-time, consented model download (see CL-1), and only with visible progress. Any failure of that download must degrade to the Apple on-device baseline rather than blocking the user.
- **Current pipeline architecture** (Data → Domain → Presentation, actor-based segmenter, fan-out from a single ASR stream) is preserved. This feature changes the engine and the quality contract, not the layering.
- **SwiftData store** introduced on the current branch (003-fix-save-export) is the persistence target for session quality records (FR-014), on iOS this time.
- **iOS UI port**: the current macOS split-pane layout is reused in spirit, but a port to iPhone-class form factors (portrait, safe areas, keyboard inset, smaller width) is implicitly part of this feature insofar as it serves the new quality contract. A full iOS visual redesign is a separate piece of work.
- **No new external dependencies** are added without explicit approval. (Mirrors the constitutional rule already in CLAUDE.md.)
- **Latency targets** are measured on the reference device class with the app in foreground, microphone permission granted, default mic, quiet ambient noise.

---

## Out of Scope

- Multi-target-language support (only en → es in this feature).
- Speaker identification or diarization beyond a coarse "speaker likely changed" hint.
- Custom accent training data collection from production users (privacy and product surface are not in scope here).
- Voice-to-voice (TTS playback of the Spanish translation).
- Real-time conversation mode (two parties alternating). Single-input live translation only.
- A full iOS visual redesign beyond what the new quality signals require.
- Continued macOS shipping target. macOS remains available as a developer workstation but is not the product surface for this feature (see CL-2).

---

## Clarifications Resolved

> Three scope-shaping decisions were asked and answered during specification. They are now part of the contract.

### CL-1 — Network/privacy tier: **on-device with consented one-time download**

The app may ship (or download on first run) a heavier on-device speech-recognition model that runs entirely without network at use time. Network is allowed **only** for the initial model download and **only** with explicit user consent and visible progress. No runtime network calls for transcription or translation. This unlocks materially higher accuracy on L2 accents than the Apple-only path without introducing a cloud privacy surface.

### CL-2 — Platform target: **iOS only**

This feature ships on **iOS only** (iPhone, with iPad as best-effort). The current macOS app is not part of this feature's deliverable. Implications already baked into the spec:

- Reference device class in *Assumptions* is now a modern iPhone (not Apple Silicon Mac).
- Model footprint and battery are first-class constraints; a downloadable on-device model must fit within a budget the iOS app review process and user expectation allow.
- The split-pane UI must be ported / re-laid-out for portrait iPhone form factors. That port is in scope for this feature only insofar as it serves the new contract; a full iOS UI overhaul is a separate piece of work.
- Latency envelope SC-006 is retained but flagged for re-confirmation against the reference iPhone during the plan phase.

### CL-3 — Confidence UI form: **tonal styling of the caption text**

Low-confidence tokens are rendered with reduced opacity / lighter weight inline in the caption itself. No badges, no `[unclear]` markers, no hover gestures. This integrates with the existing two-pane reading flow and satisfies US2's "distinguish at a glance" acceptance test without adding new chrome.

---

## Notes on Scope Boundary with `/speckit-plan`

The original request from the user asked for a three-phase technical analysis (FASE 1 diagnóstico, FASE 2 opciones técnicas — Whisper API vs whisper.cpp vs fine-tuning vs LLM ensemble vs Apple Translation, FASE 3 recomendación). That analysis belongs in `/speckit-plan`, not in this spec, because it is implementation-shaped: it picks engines, frameworks, and integration approaches. This spec defines the user-facing contract and the measurable outcomes those technical options will be judged against. The plan phase will return to FASE 2 / FASE 3 with the option matrix and one recommendation, evaluated against SC-001 through SC-010 above.
