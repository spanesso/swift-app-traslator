# Feature Specification: Accent-Robust Speech Recognition

**Feature Branch**: `004-whisperkit-asr`
**Created**: 2026-06-02
**Status**: Draft

## User Scenarios & Testing *(mandatory)*

### User Story 1 — First Launch: Model Download (Priority: P1)

A user opens the app for the first time after the update. The app automatically downloads the speech recognition model in the background. The user sees a clear progress indicator so they know something is happening and does not think the app is broken. Once the download completes, transcription starts automatically without any manual action.

**Why this priority**: Without a smooth download experience, every new user hits a blank screen and abandons the app. This is the gate that unlocks all other functionality.

**Independent Test**: On a clean install, open the app and observe the download indicator. When it reaches 100%, begin speaking and verify transcription appears — without restarting the app or pressing any extra button.

**Acceptance Scenarios**:

1. **Given** the app is opened for the first time, **When** the home screen appears, **Then** a progress indicator is visible in the translation pane showing download percentage.
2. **Given** the model is downloading, **When** the user presses Record, **Then** a clear message explains the model is still loading (recording does not silently fail).
3. **Given** the download completes, **When** the progress indicator disappears, **Then** the app immediately allows transcription without requiring a restart.
4. **Given** a download was interrupted (network loss), **When** the app is reopened, **Then** the download resumes from where it left off.

---

### User Story 2 — Transcription With Any English Accent (Priority: P1)

A user whose native language is not American English (e.g., British, Indian, Australian, Colombian, Nigerian, Filipino) speaks into the microphone. The app transcribes their words accurately, including domain-specific vocabulary, proper nouns, and natural speech patterns such as contractions and false starts.

**Why this priority**: This is the core value proposition of the entire feature. If accent recognition fails, the translation is meaningless.

**Independent Test**: A speaker with a non-American English accent records a 2-minute monologue. At least 90% of words are correctly transcribed and passed to the translation engine.

**Acceptance Scenarios**:

1. **Given** the app is recording, **When** a speaker with a British accent speaks, **Then** the English pane shows correctly transcribed text with no more than 10% word error rate.
2. **Given** the app is recording, **When** a speaker with an Indian or South Asian accent speaks, **Then** transcription accuracy is equivalent to an American English speaker in the previous version.
3. **Given** the app is recording, **When** a speaker with a Spanish-influenced English accent speaks, **Then** the app correctly transcribes common false cognates and accent-related pronunciation patterns.
4. **Given** any English accent, **When** the speaker finishes a sentence and pauses, **Then** the completed phrase is sent to the translation engine within 3 seconds.

---

### User Story 3 — Seamless Long Sessions Without Freezing (Priority: P2)

A user runs the app continuously for 10+ minutes during a meeting or presentation. The transcription never silently freezes. If the recognition engine needs to internally reset (due to audio session timeout or model state), it does so transparently — the user sees no interruption, no error message, and no loss of text already captured.

**Why this priority**: Long sessions are the primary use case (meetings, presentations). A freeze at minute 2 makes the tool unusable professionally.

**Independent Test**: Run the app for 15 minutes of continuous speech. Verify that transcribed text continues to appear throughout, with no gaps longer than 5 seconds that are not caused by actual silence.

**Acceptance Scenarios**:

1. **Given** the app has been recording for 5 minutes, **When** the internal recognition session resets, **Then** transcription resumes within 1 second and previously captured text is not lost.
2. **Given** the recognition engine stalls for any reason, **When** 30 seconds pass without output, **Then** the app automatically recovers without user intervention.
3. **Given** the user presses the Restart button manually, **When** the restart completes, **Then** all previously transcribed and translated text is preserved.

---

### User Story 4 — Subsequent Launches: Instant Start (Priority: P2)

A user who has already downloaded the model opens the app again. Transcription is available immediately — there is no download delay, no loading screen, no wait. The model loads from local storage in the background while the UI is already visible.

**Why this priority**: Repeated use is the measure of a successful tool. A slow startup on every launch kills the habit loop.

**Independent Test**: With the model already downloaded, open the app, press Record, and speak within 5 seconds. Verify transcription text appears.

**Acceptance Scenarios**:

1. **Given** the model was previously downloaded, **When** the app opens, **Then** no download indicator is shown.
2. **Given** the app has just opened, **When** the user presses Record within 5 seconds, **Then** transcription begins without error.
3. **Given** the app has been closed and reopened multiple times, **Then** the model is never re-downloaded from the internet.

---

### Edge Cases

- What happens if the user's disk is full and the model cannot be saved?
- What happens if the download is interrupted at 80% and the app is force-quit?
- What happens if the microphone permission is revoked mid-session?
- What happens if the user speaks a mix of English and another language?
- What happens on a Mac without a dedicated GPU (older Intel Mac)?

---

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The app MUST support English speech from any regional accent (American, British, Australian, Indian, Irish, South African, Caribbean, Filipino, Nigerian, etc.) with consistent accuracy.
- **FR-002**: The app MUST display a download progress indicator (percentage) the first time the recognition model is required, before any transcription attempt begins.
- **FR-003**: The app MUST begin transcription automatically after model download completes, without requiring the user to take any additional action.
- **FR-004**: The model MUST be stored locally after the first download and reused on all subsequent sessions without re-downloading.
- **FR-005**: The app MUST recover automatically from recognition engine stalls within 30 seconds, without user intervention and without losing previously captured text.
- **FR-006**: The app MUST continue to support the full translation pipeline (EN → ES) and conversation save/export features without any regression.
- **FR-007**: The recognition engine MUST operate fully offline once the model is downloaded — no internet connection required for transcription.
- **FR-008**: The app MUST preserve all previously transcribed and translated text when the recognition engine restarts (whether automatic or user-triggered).
- **FR-009**: If the model download fails, the app MUST display a clear error message and allow the user to retry.
- **FR-010**: On devices where the on-device model is unavailable or too slow, the app MUST fall back to the previous system-level speech recognition automatically.

### Key Entities

- **Recognition Model**: The downloadable AI model (~800 MB) stored in local app cache. Has states: not-downloaded, downloading (with progress 0–100%), ready, loading, active.
- **Download Progress**: A real-time percentage value (0.0–1.0) reported during the initial model fetch. Displayed in the translation pane as a progress bar.
- **Speech Segment**: An utterance chunk emitted by the recognition engine. Has a text content, a finality flag (partial vs. committed), and a confidence score.

---

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A speaker with any English regional accent achieves a word error rate below 10% on standard conversational English — measured on a 2-minute recording.
- **SC-002**: On first launch, the model download completes and transcription is available within the time it takes the download to finish — no additional setup steps required.
- **SC-003**: On subsequent launches, transcription is available within 5 seconds of opening the app.
- **SC-004**: Continuous recording sessions of 15 minutes produce no silent freezes — any internal reset is invisible to the user.
- **SC-005**: 100% of text captured before a recognition restart is preserved and visible after the restart.
- **SC-006**: The app operates fully offline (no network requests during a recording session after model is downloaded).
- **SC-007**: The translation pipeline accuracy and speed are unchanged compared to the previous version — the improvement is in recognition only.

---

## Assumptions

- The app targets macOS 14+ (Sonoma), which provides sufficient on-device compute for the chosen recognition model.
- The selected model size (~800 MB) is acceptable for a professional productivity tool — users of this category routinely download comparable reference databases and fonts.
- Internet connectivity is required only once, for the initial model download; all subsequent use is offline.
- The existing English → Spanish translation pipeline (Apple on-device Translation framework) is unchanged and remains the downstream consumer of transcribed text.
- The current conversation save, export, and history features are out of scope for this feature — they must continue to work as-is but are not modified.
- Fallback to the previous system recognition is acceptable on older hardware where the model performs below the success criteria thresholds.
- No user account, authentication, or cloud processing is involved at any point.
