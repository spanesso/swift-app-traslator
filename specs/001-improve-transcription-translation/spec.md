# Feature Specification: Improve Live Transcription & Translation Quality

**Feature Branch**: `001-improve-transcription-translation`  
**Created**: 2026-04-17  
**Status**: Draft  
**Input**: User description: "Mejorar calidad de transcripción y traducción en vivo (iOS/Swift)"

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Clean Streaming Transcription Display (Priority: P1)

A user speaks continuously and sees their words appear progressively in the original-language column without duplicates, mid-word cuts, or repeated blocks. The display reflects real-time speech naturally, like a live caption.

**Why this priority**: This is the most visible failure today — duplicated and repeated text in the original column breaks basic trust in the app and is noticeable to any user within seconds.

**Independent Test**: Can be fully tested by speaking continuously for 2 minutes and verifying the original column never shows repeated lines, cut words, or garbled text. Delivers a usable live caption experience even without translation.

**Acceptance Scenarios**:

1. **Given** the app is recording, **When** the user speaks a sentence, **Then** the words appear progressively in the original column without any word being shown twice.
2. **Given** the user has been speaking for 30+ seconds, **When** reviewing the original column, **Then** no paragraph or phrase block appears more than once.
3. **Given** the user pauses mid-sentence and resumes, **When** the speech resumes, **Then** the display continues cleanly from where it left off without repeating prior content.

---

### User Story 2 - Semantic Sentence Segmentation (Priority: P2)

The app waits until a complete semantic unit (a full sentence or natural phrase boundary) is ready before sending it for translation, rather than cutting text at arbitrary chunk boundaries.

**Why this priority**: The root cause of incoherent translations is sending fragments like "know the nutshell as we kind of" or "Corp." without context. Fixing segmentation directly fixes translation quality.

**Independent Test**: Can be tested by speaking a set of 10 sentences and verifying that no sentence boundary is split across two separate translation requests. Delivers dramatically improved translation coherence even before context windowing is added.

**Acceptance Scenarios**:

1. **Given** the user speaks "In a nutshell, we restructured different things.", **When** translation is triggered, **Then** the entire sentence is sent as one unit — not "In a nutshell, we" and "restructured different things." separately.
2. **Given** the user speaks a sentence ending with ".", "?", or "!", **When** the punctuation is detected, **Then** translation is triggered for that complete sentence.
3. **Given** the user pauses for more than ~800ms without ending punctuation, **When** the silence threshold is reached, **Then** the accumulated text is flushed and translated as a unit.
4. **Given** the user speaks without pausing for more than 20 words, **When** the maximum phrase limit is reached, **Then** the text is flushed at the last natural clause boundary (not mid-word).

---

### User Story 3 - Context-Aware Translation (Priority: P3)

Translated sentences account for what was said earlier in the session, so idioms, pronouns, and references are resolved correctly in context rather than translated in isolation.

**Why this priority**: Even with perfect segmentation, a stateless translator produces errors like "nutshell" → "nueza" instead of "en pocas palabras". Context from prior sentences enables idiomatic, coherent translation.

**Independent Test**: Can be tested by speaking a paragraph containing at least one idiom and one pronoun reference that spans sentences, then verifying both are translated correctly. Delivers professional-grade translation quality.

**Acceptance Scenarios**:

1. **Given** the user previously said "We're going to cover this in a nutshell", **When** the phrase is translated, **Then** "in a nutshell" renders as "en pocas palabras" (not "en la cáscara de una nuez" or "nueza").
2. **Given** the user says "She presented the report. It was excellent.", **When** the second sentence is translated, **Then** "It" resolves correctly to the report in context (not as a generic pronoun).
3. **Given** the session has accumulated 10+ sentences, **When** a new sentence is translated, **Then** the translation considers at least the last 3–5 sentences of prior context.

---

### User Story 4 - Stable Translation Column (Priority: P4)

The translated-language column only shows finalized, complete translations. It never flickers, rewrites prior lines, or shows partial mid-translation fragments.

**Why this priority**: A stable translation column is essential for readability. Rewriting previous translations or showing partial text is disorienting and makes the output unusable in professional settings.

**Independent Test**: Can be tested by observing the translation column for 5 minutes of continuous speech and verifying that no previously displayed translation line is ever modified or replaced.

**Acceptance Scenarios**:

1. **Given** a translation has been appended to the translation column, **When** subsequent speech is processed, **Then** the previously displayed translated line is never modified or removed.
2. **Given** a sentence is being processed for translation, **When** the translation is not yet complete, **Then** no partial or placeholder text appears in the translation column.
3. **Given** the user speaks a sentence identical to a prior sentence, **When** translation completes, **Then** the duplicate is detected and not appended again.

---

### Edge Cases

- What happens when the user stops speaking mid-sentence and never resumes? The accumulated partial text should be flushed and translated after a maximum hold time (e.g., 5 seconds).
- How does the system handle very fast speech where no pauses or punctuation occur for 30+ words? A forced flush at a configurable word-count ceiling prevents indefinite retention.
- What happens if speech recognition returns a partial result that is later revised (e.g., "know" corrected to "no")? The final result must replace the partial cleanly without leaving the original partial visible.
- How does the system handle a topic change mid-session? Context window should be bounded (e.g., last N sentences) so stale context from a prior topic does not pollute new translations.
- What happens when the user taps Stop while text is still buffered for translation? Buffered content should be flushed and translated before the session closes.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The original-language column MUST display speech progressively as words are recognized, updating in near-real-time.
- **FR-002**: The translated-language column MUST only display complete, finalized translations — never partial fragments.
- **FR-003**: The system MUST segment speech into translation units at sentence-ending punctuation (`.`, `?`, `!`).
- **FR-004**: The system MUST segment speech into translation units upon detecting a sustained silence of configurable duration (default: 800ms).
- **FR-005**: The system MUST force-flush accumulated text for translation when a configurable maximum phrase length is reached (default: 20 words) even without a detected boundary.
- **FR-006**: Each translation unit MUST be translated with access to the context of the N most recently translated sentences (default N: 5).
- **FR-007**: The system MUST prevent the same text from being emitted for translation more than once per session.
- **FR-008**: The original-language column MUST NOT display duplicate lines or repeated content at any point during a session.
- **FR-009**: When a partial speech recognition result is superseded by a corrected final result, the display MUST update cleanly without leaving stale text visible.
- **FR-010**: The system MUST handle the user stopping recording while text is buffered by flushing and translating buffered content before closing the session.
- **FR-011**: All speech recognition and translation MUST function without internet connectivity (on-device processing).
- **FR-012**: The silence threshold (FR-004), maximum phrase length (FR-005), and context window size (FR-006) MUST be configurable parameters with documented default values.

### Key Entities

- **Speech Segment**: A unit of recognized speech with a text value, a finality flag (partial vs. final), and a confidence score.
- **Translation Unit**: A semantically complete phrase or sentence extracted from one or more speech segments, ready to be translated.
- **Translation Context Window**: The ordered collection of the N most recently finalized (original, translated) sentence pairs used to inform the next translation.
- **Session Buffer**: The accumulated unfinalized text since the last translation flush, including the current in-progress speech segment.
- **Translation Result**: A finalized translated string paired with its source translation unit, appended immutably to the translation column.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: Translated text appears within 2 seconds of the user completing a sentence (ending with punctuation or a silence pause).
- **SC-002**: Zero duplicate lines appear in the original transcription column across a 10-minute continuous recording session.
- **SC-003**: At least 90% of idiomatic expressions (e.g., "in a nutshell", "on the other hand") are rendered contextually in the target language rather than word-for-word.
- **SC-004**: Sentence boundaries are correctly preserved in at least 95% of translation requests — no sentence is split across two separate translation calls.
- **SC-005**: The app remains fully functional (no crashes, no UI freezes, no text corruption) across sessions of 30+ minutes.
- **SC-006**: All features work fully offline — no network connection is required for transcription or translation.

## Assumptions

- The primary language pair is English (source) to Spanish (target); the spec describes the behavior for this pair, but the design should not prevent future language pairs.
- The app runs on macOS (not iOS/iPadOS) based on project conventions; all on-device processing must work within macOS audio and speech recognition capabilities.
- The translation engine in use is Apple's on-device Translation framework; context injection must work within the constraints of that engine (no custom LLM prompt is assumed).
- Silence detection relies on the absence of new speech recognition results rather than raw audio VAD; this is consistent with the existing architecture.
- The context window (FR-006) holds sentence-level pairs in memory for the duration of the session only; no cross-session persistence is required.
- A "sentence" for segmentation purposes is defined as text ending with `.`, `?`, or `!`, or text that has been stable (no new ASR updates) for the configured silence threshold.
- The maximum phrase length flush (FR-005) cuts at the last detected clause marker within the buffer, not at an arbitrary word count, to avoid mid-phrase cuts.
- The configurable parameters (silence threshold, max phrase length, context window size) are developer-facing settings with sensible defaults; no user-facing settings UI is required in this iteration.
