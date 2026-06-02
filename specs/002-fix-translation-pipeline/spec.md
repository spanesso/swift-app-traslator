# Feature Specification: Fix Translation Pipeline — Stable Real-Time Transcription & Translation

**Feature Branch**: `002-fix-translation-pipeline`
**Created**: 2026-06-01
**Status**: Draft
**Input**: Diagnose and fix the real-time transcription → segmentation → translation pipeline so that it runs stably, restarts cleanly, and never silently drops or duplicates phrases.

---

## User Scenarios & Testing *(mandatory)*

### User Story 1 — Fluid Transcription and Translation During a Recording Session (Priority: P1)

A user opens the app, taps Record, and speaks in English. Within a few seconds, the left pane shows the in-progress English text and the right pane shows the translated Spanish phrases, updating continuously as the user speaks. Neither pane freezes or stops updating mid-session.

**Why this priority**: This is the core value proposition. If translation stops mid-session the app is unusable.

**Independent Test**: Start a recording, speak five complete sentences. Verify that all five sentences appear in the Spanish pane without manual intervention.

**Acceptance Scenarios**:

1. **Given** the app is in idle state, **When** the user taps Record and speaks a complete sentence in English, **Then** a Spanish translation of that sentence appears in the right pane within 3 seconds.
2. **Given** the user is speaking continuously, **When** a new stable phrase is detected, **Then** the Spanish pane appends the translation without overwriting or duplicating prior sentences.
3. **Given** the user has been speaking for 60 seconds, **When** they continue speaking, **Then** both panes continue updating; neither pane is blank or frozen.

---

### User Story 2 — Clean Stop and Restart (Priority: P1)

A user taps Stop after a session, then taps Record again to start a new session. The new session starts fresh — prior text is cleared, and transcription and translation resume immediately without residual state from the previous session.

**Why this priority**: Sessions sticking together or the translation engine not reinitialising after stop is a known failure mode that makes the app unusable after the first session.

**Independent Test**: Complete a full session (Record → speak → Stop). Immediately tap Record again and speak new content. Verify: old text is gone, new text appears, translation resumes.

**Acceptance Scenarios**:

1. **Given** a completed session, **When** the user taps Stop, **Then** all background audio and processing tasks terminate within 2 seconds.
2. **Given** a previous session has ended, **When** the user taps Record again, **Then** both text panes are cleared and new content appears from scratch.
3. **Given** the user restarts the session three times in a row, **When** each session begins, **Then** translation resumes correctly each time without requiring an app restart.

---

### User Story 3 — No Duplicate or Missed Phrases (Priority: P2)

When a user speaks a sequence of distinct sentences, each sentence appears exactly once in the Spanish pane. No sentence is repeated, and no sentence that was clearly spoken is silently skipped.

**Why this priority**: Duplicates and dropped phrases directly degrade trust in the app output.

**Independent Test**: Speak five short sentences with natural pauses between them. Count: the Spanish pane should show exactly five translated entries, each different.

**Acceptance Scenarios**:

1. **Given** the user speaks a sentence that ends with a natural pause, **When** the translation appears, **Then** it appears exactly once in the Spanish pane.
2. **Given** the user speaks two consecutive sentences quickly, **When** both are translated, **Then** both appear as separate entries in order.
3. **Given** a phrase is very short (fewer than 3 words), **When** the system processes it, **Then** it is either deferred and merged with adjacent context or skipped with a log entry — it is never translated as an isolated micro-phrase.

---

### User Story 4 — Visible Errors and Graceful Recovery (Priority: P2)

When the app encounters a problem (microphone permission denied, speech recognition unavailable, translation model not downloaded), it displays a clear, human-readable message. The user is not left looking at a silent, frozen interface.

**Why this priority**: Silent failures make users think the app is working when it is not.

**Independent Test**: Revoke microphone permission, tap Record. Verify that a descriptive error message is shown and the Record button returns to its inactive state.

**Acceptance Scenarios**:

1. **Given** microphone permission is not granted, **When** the user taps Record, **Then** an error message explains the permission is missing and prompts the user to grant it.
2. **Given** the device's on-device translation model is not available, **When** a phrase reaches the translation stage, **Then** the English text remains visible and an error banner is shown instead of a blank Spanish pane.
3. **Given** the speech recognition service returns an error mid-session, **When** the error is detected, **Then** the recording stops cleanly, the button resets, and the error is displayed.

---

### Edge Cases

- What happens when the user speaks without any pause for more than 30 seconds (very long monologue)?
- What happens when the device microphone is disconnected mid-session?
- What happens when the user taps Record/Stop rapidly multiple times in succession?
- What happens when the on-device translation model has not been downloaded yet?
- What happens when the ASR engine returns an empty or whitespace-only transcript update?
- What happens when the user speaks in a language other than English?

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST start transcription and translation together when the user taps Record, without requiring a separate action.
- **FR-002**: The system MUST display English ASR output in the left pane continuously while the user is speaking, updating with each new partial result.
- **FR-003**: The system MUST send stable, complete phrase segments (not every partial update) to the translation engine to avoid micro-translations.
- **FR-004**: The system MUST deliver translated phrases to the Spanish pane without blocking, stalling, or requiring user intervention mid-session.
- **FR-005**: The system MUST support fan-out: the same audio input MUST feed both the live English display and the translation pipeline simultaneously without either consumer starving the other.
- **FR-006**: The system MUST terminate all active processing tasks cleanly when the user taps Stop, releasing audio resources within 2 seconds.
- **FR-007**: The system MUST reset all state (text buffers, phrase history, processing queues) when a new session starts, so no content from a previous session appears.
- **FR-008**: The system MUST prevent duplicate translated phrases from appearing in the Spanish pane across an entire session.
- **FR-009**: The system MUST handle the case where the translation engine is not yet ready (model not downloaded, initialising) by displaying a status indicator rather than silently dropping phrases.
- **FR-010**: The system MUST display a descriptive error message when microphone permission is denied, when speech recognition is unavailable, or when the translation service fails.
- **FR-011**: The system MUST log all significant pipeline events (phrase detected, phrase sent for translation, translation received, error encountered) to the system log with a structured, searchable format.
- **FR-012**: The system MUST allow the user to stop and restart recording at least three consecutive times within one app session without degradation or requiring an app restart.
- **FR-013**: The system MUST guard against micro-phrases (fewer than a configurable minimum word count) reaching the translation engine.
- **FR-014**: Segmentation MUST flush any buffered partial phrase when the user stops recording, so the last words spoken are not lost.

### Key Entities

- **SpeechSegment**: A unit of transcribed audio carrying the full accumulated ASR text, a finality flag, and a confidence score.
- **StablePhrase**: A complete, deduplicated phrase extracted from the continuous ASR stream, ready to be sent to translation.
- **TranslationRequest**: A single stable phrase queued for translation, with ordering preserved.
- **TranslationResult**: The translated text returned for a given phrase, tied to its source for deduplication.
- **SessionState**: Enum capturing the current state of the pipeline: idle, recording, stopping, error.
- **QualitySnapshot**: Aggregated ASR quality signals (revision rate, stability delay, confidence, words-per-second) recorded per session.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A complete sentence spoken by the user appears translated in the Spanish pane within 3 seconds of the phrase ending, in at least 9 out of 10 trials under normal network-free conditions.
- **SC-002**: After 3 consecutive stop-and-restart cycles, the app continues to transcribe and translate correctly without requiring a restart, in 100% of trials.
- **SC-003**: Zero duplicate translated phrases appear in the Spanish pane within a single recording session.
- **SC-004**: Zero phrases that were spoken clearly and lasted more than 3 words are silently dropped — each either appears translated or triggers a logged explanation.
- **SC-005**: All background processing tasks terminate within 2 seconds of the user tapping Stop, verifiable via system log timestamps.
- **SC-006**: When a permission or engine error occurs, a visible, human-readable message appears within 1 second of the error being detected.
- **SC-007**: The app remains responsive (no UI freeze > 200 ms) throughout a continuous 3-minute recording session.

---

## Assumptions

- The app targets macOS with an on-device translation model already downloaded; first-time download flows are out of scope for this fix but errors must be surfaced gracefully.
- The language pair is fixed at English (input) → Spanish (output); a language picker is explicitly out of scope for this feature.
- Audio input is from the default macOS microphone; external microphone handling is out of scope.
- The minimum phrase length threshold (word count) for translation is a configurable constant, defaulting to 2 words.
- The segmentation stability timer duration is a configurable constant, defaulting to 0.7 seconds.
- The app does not persist transcription or translation output between sessions; all data is in-memory only.
- Quality metrics are recorded internally and exposed via logs; no external dashboard or UI widget for metrics is in scope for this feature.
- The fix resolves existing unresolved git merge conflicts in the codebase as part of the implementation; both conflicting versions will be evaluated and the best approach from each retained.
- No new third-party dependencies will be introduced; only Apple-provided frameworks are used.
