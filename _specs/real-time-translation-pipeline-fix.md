# Specification: Real-Time Translation Pipeline Fix & Readability Overhaul

## 1. Overview
**Feature Slug:** `real-time-translation-pipeline-fix`
**Status:** Approved
**User Story:** As a professional in a business video call, I want the app to reliably transcribe and translate speech into clean, sequential phrases so that I can follow the conversation in real time without confusion or missing translations.

---

## 2. Context & Objectives
- **Problem:** Three compounding failures degrade the experience: (a) translations frequently do not fire because the `.translationTask` SwiftUI view is not properly recreated between recording sessions; (b) the segmenter may swallow phrases by not emitting when speaking pauses between sentences; (c) both panes display text in a way that is hard to scan quickly — a wall of accumulated text rather than a sequential, phrase-by-phrase feed.
- **Goal:** Every stable speech phrase is translated exactly once and displayed in a format that is immediately legible at a glance.
- **Non-Goals:** Language-pair selection UI, adaptive quality strategy activation, multi-speaker diarization, network-based translation, changes to the audio engine or ASR layer.

---

## 3. Acceptance Criteria
*These are the hard requirements for the feature to be considered "Done".*
- [ ] **AC1:** Every stable phrase emitted by `NLPSegmenterService` is passed to the Apple Translation engine and a Spanish result is appended to the ES pane — no silent drops.
- [ ] **AC2:** Starting a new recording session after a previous one always produces fresh translations — the `.translationTask` is provably recreated on each session start.
- [ ] **AC3:** The segmenter emits a phrase when the speaker pauses, even if the final fragment is fewer than 5 words, as long as it is new content (i.e., not already emitted).
- [ ] **AC4:** The ES pane displays one translated phrase per visual block, with clear visual separation, using a font size and weight readable at a glance during a screen-share.
- [ ] **AC5:** The EN pane shows the current in-progress phrase (live partial ASR) clearly distinct from already-confirmed speech, so the user can track what is being recognized right now.
- [ ] **AC6:** Neither pane ever displays a duplicate phrase within the same recording session.
- [ ] **AC7:** When recording stops, both panes retain the last session's content until the next recording session starts (content persists, not wiped on stop).

---

## 4. Functional Requirements & Logic

### FR1 — `.translationTask` Lifecycle (Fix for AC1, AC2)
The `taskID` state variable must be assigned a new `UUID()` every time recording starts, before `translationConfig` is set. This forces SwiftUI to destroy and recreate the view subtree that owns `.translationTask`, guaranteeing a fresh session with a fresh stream reference.

**Business Rule:** The sequence on recording start must be: (1) create new `AsyncStream` + continuation, (2) assign new `taskID`, (3) set `translationConfig`. Order is strict — if `translationConfig` is set before the stream is ready, the translation handler will see `nil` requests and exit silently.

### FR2 — Segmenter Emission on Pause (Fix for AC3)
The `NLPSegmenterService` stability timer fires 1.4 s after the last ASR update. The word-count gate (`>= 5 words`) must be relaxed when the segment is marked `isFinal` by the ASR. A final segment must be emitted regardless of word count, as long as it contains at least 2 words and has not already been emitted (i.e., `newFullText != lastEmittedFullText`).

**Business Rule:** A phrase ending with a sentence-terminal punctuation mark (`.`, `?`, `!`) is always treated as emittable regardless of word count.

### FR3 — Differential Segmentation Robustness
When a speaker pauses mid-sentence and the ASR fires a final segment that equals the last emitted text (`newFullText == lastEmittedFullText`), the segmenter must not emit a duplicate. When `newFullText` is shorter than `lastEmittedFullText` (ASR correction), the segmenter must discard that update silently. No regression to existing differential logic.

### FR4 — EN Pane: Live Buffer Display
The EN pane displays two visual zones:
1. **History zone:** Stable phrases already emitted by the segmenter — greyed-out, smaller, scrollable.
2. **Live zone:** The current in-progress `currentBuffer` (raw partial ASR) — bright/highlighted, visually distinct.

The `TranscriptionViewModel` must expose a separate `emittedPhrases: [String]` list (updated whenever the segmenter yields a phrase) in addition to `currentBuffer`, so the view can render them separately.

### FR5 — ES Pane: Phrase-Block Display
Each translated phrase is rendered as its own visual block with:
- A minimum font size of 18 pt.
- A visible separator (subtle horizontal line or generous vertical spacing) between phrases.
- The most recent phrase visually highlighted (e.g., brighter color or slightly larger).
- Auto-scroll to the latest phrase on each append.

### FR6 — Duplicate Guard Symmetry
The duplicate guard in `appendTranslation` checks both directions: drop if `trimmed == last` OR if `last.contains(trimmed)` OR if `trimmed.contains(last)`. This prevents partial-overlap re-emissions.

### FR7 — Session Reset on Start
When a new recording session starts, `emittedPhrases`, `currentBuffer`, and `translatedSentences` are all cleared. The EN and ES panes show empty / placeholder state until the first content arrives.

---

## 5. User Interface & Experience (Behavioral)

- **Entry Point:** User taps the record button.
- **Success State:**
  - EN pane: faint historical phrases at the top, bold live partial at the bottom.
  - ES pane: each translated phrase in its own block, newest at bottom, auto-scrolled into view, large readable font.
  - No gaps, no missing translations, no duplicate lines.
- **Idle State:** Both panes show a subtle placeholder ("Waiting for audio…" / "Esperando audio…") in grey.
- **Error States:** If the translation engine returns an error, the phrase that failed is silently skipped (not shown as garbled text); the engine continues for subsequent phrases. An interrupted-session error triggers `stopRecording()` as it does today.

---

## 6. Possible Edge Cases

- **Edge Case 1 — Rapid speech:** Speaker produces many phrases faster than the translation engine can process. The `AsyncStream` naturally buffers; translations will appear slightly delayed but in order. No phrases must be dropped due to backpressure.
- **Edge Case 2 — Very short utterances:** Single words or two-word fragments. FR2 defines the floor at 2 words for final segments; sub-2-word finals are discarded silently.
- **Edge Case 3 — Recording restarted immediately:** User stops and restarts within 1 second. The new `taskID` and stream must be fully initialized before the old translation session tears down. The `stopRecording` path must synchronously finish the old continuation before `startRecording` creates the new one.
- **Edge Case 4 — ASR produces no finals (low-quality mic):** The stability timer still fires 1.4 s after the last partial, so segmentation proceeds even if `isFinal` is never set.
- **Edge Case 5 — Large translation backlog on stop:** When the user stops recording, any phrases already in the stream buffer should still be translated and displayed. The translation engine should only stop after the stream is exhausted.

---

## 7. Open Questions
- [ ] **Q1:** Should the EN history zone be capped at N phrases to avoid the pane becoming too long during a long meeting? Propose cap of 20 phrases with oldest removed from top.
- [ ] **Q2:** Should the phrase highlight on the ES pane fade out after 3 seconds to avoid visual noise in long sessions?
- [ ] **Q3:** Is the 1.4 s stability delay still correct for fast speakers? Consider making it a tunable constant tied to `QualityMetricsService`.

---

## 8. Definition of Done (DoD)
- [ ] All Acceptance Criteria (Section 3) are met.
- [ ] Code follows the Clean Architecture layers defined in `CLAUDE.md` — no cross-layer leaks.
- [ ] `NLPSegmenterService`, `TranscriptionViewModel`, and `LiveTranscriptionView` are the only files modified.
- [ ] No regression: stopping and restarting recording multiple times within a session works correctly every time.
- [ ] OSLog entries confirm phrase emission → translation request → translation display for each phrase in a test session.
