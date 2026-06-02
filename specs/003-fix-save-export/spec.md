# Feature Specification: Fix Pipeline Freeze, Conversation History & Export

**Feature Branch**: `003-fix-save-export`
**Created**: 2026-06-02
**Status**: Draft
**Input**: User description: "Fix speech-to-text/translation pipeline freeze after a few minutes, add SwiftData persistence for conversations, conversation history list & detail view, and email/share export of conversation transcripts."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Sustained Long Session Without Freeze (Priority: P1)

A user starts a real-time speech-to-text + translation session, speaks for 5–15 minutes without interruption, and the system continues producing transcription and translation output throughout — it never silently stops or freezes mid-session.

**Why this priority**: This is a regression bug. The app is currently unusable for any real conversation of significant length. Everything else builds on a working pipeline.

**Independent Test**: Start recording, speak continuously for 10 minutes, verify both the English transcription buffer and Spanish translations keep updating. No manual intervention should be required.

**Acceptance Scenarios**:

1. **Given** the app is recording and translating, **When** 5 minutes of continuous speech have elapsed, **Then** new speech is still transcribed and translated without requiring the user to stop and restart.
2. **Given** the app is recording and translating, **When** the user pauses speaking for 30 seconds and then resumes, **Then** transcription and translation resume normally.
3. **Given** the app is recording, **When** the system resources are under moderate load, **Then** the pipeline does not stall or freeze.

---

### User Story 2 - Save a Completed Conversation (Priority: P2)

After finishing a session, the user taps a "Save" button and the full conversation — English transcript and Spanish translation — is stored locally in a persistent conversation history. The user can close and reopen the app and still see the saved record.

**Why this priority**: Persistence of conversation records is the primary new feature requested; it provides lasting value from each recorded session.

**Independent Test**: Complete a session, tap Save, force-quit the app, reopen, navigate to history — the saved conversation appears with its English and Spanish content intact.

**Acceptance Scenarios**:

1. **Given** a session has been recorded and translated, **When** the user taps "Save Conversation", **Then** the conversation is stored persistently with the full English text and the full Spanish translation.
2. **Given** a session has been saved, **When** the app is closed and reopened, **Then** the saved conversation appears in the history list.
3. **Given** the user has saved multiple conversations, **When** they view the history list, **Then** each entry shows a date/time stamp and a short preview of the English text.
4. **Given** a session is active (recording in progress), **When** no session has yet been recorded, **Then** the Save button is disabled or hidden.

---

### User Story 3 - Browse and Read Saved Conversations (Priority: P2)

The user navigates to a "History" section that lists all saved conversations. Tapping an entry opens a detail view showing the English text on one half and the Spanish translation on the other half, side by side or split vertically.

**Why this priority**: Without a way to review saved sessions, storing them provides no value. This completes the persistence feature.

**Independent Test**: Save two conversations with different content, navigate to History, verify both appear, tap each, verify the correct English and Spanish texts are shown in a split-pane layout.

**Acceptance Scenarios**:

1. **Given** at least one conversation has been saved, **When** the user opens the History list, **Then** all saved conversations appear ordered by date (most recent first).
2. **Given** the History list is shown, **When** the user taps a conversation entry, **Then** a detail view opens showing the English text in one panel and the Spanish translation in another, side-by-side or split.
3. **Given** no conversations have been saved yet, **When** the user opens the History list, **Then** an appropriate empty-state message is shown.
4. **Given** the detail view is open, **When** the text content is longer than the visible area, **Then** each panel scrolls independently.

---

### User Story 4 - Export a Conversation via Email or Share Sheet (Priority: P3)

After a session (or from the history detail view), the user taps an "Export" button and shares the English transcript and Spanish translation via the native iOS/macOS share sheet (Mail, AirDrop, Messages, Files, etc.).

**Why this priority**: Sharing is an important distribution mechanism but is not blocking — users can already read saved conversations in the app.

**Independent Test**: From a saved conversation detail view, tap Export, verify the system share sheet appears with both the English and Spanish texts included as shareable content.

**Acceptance Scenarios**:

1. **Given** a session has just ended (or a history record is open), **When** the user taps "Export", **Then** the native share sheet appears with the English and Spanish texts available to share.
2. **Given** the share sheet is presented, **When** the user selects Mail, **Then** the Mail compose window opens pre-populated with both the English transcript and the Spanish translation in the message body.
3. **Given** the share sheet is presented, **When** the user selects another destination (Messages, AirDrop, Files, etc.), **Then** the content is shared via that mechanism without error.
4. **Given** a session is still in progress (recording active), **When** the user has not yet stopped recording, **Then** the Export button is disabled or not shown.

---

### Edge Cases

- What happens when the user taps Save with an empty transcript (no speech was captured)?
- What happens if storage space is exhausted when trying to save a conversation?
- What happens if the user navigates away from the live view while a session is still recording?
- How does the history list behave when a very large number of conversations have been saved (scrolling performance)?
- What happens if the translation for a segment is still in-flight when the user taps Save — is the partial translation saved or does the app wait?

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The speech-to-text and translation pipeline MUST continue producing output for sessions of at least 15 minutes without stalling, freezing, or requiring a manual restart.
- **FR-002**: The app MUST provide a "Save Conversation" action that persists the current session's full English transcript and full Spanish translation to local storage.
- **FR-003**: Saved conversations MUST survive app termination and be available on subsequent launches.
- **FR-004**: Each saved conversation record MUST include: the complete English transcript, the complete Spanish translation, and the date and time it was saved.
- **FR-005**: The app MUST display a History screen listing all saved conversation records, ordered by date (newest first).
- **FR-006**: Each row in the History list MUST show the save date/time and a short preview (first ~100 characters) of the English text to help users identify sessions.
- **FR-007**: Tapping a History list entry MUST open a detail view that presents the English text and the Spanish translation in a split/two-panel layout.
- **FR-008**: In the detail view, each panel MUST be independently scrollable when content exceeds the visible area.
- **FR-009**: The app MUST provide an "Export" action (accessible from both the live session end state and the history detail view) that opens the native system share sheet with the full English transcript and Spanish translation as shareable content.
- **FR-010**: The "Save" and "Export" actions MUST be disabled or hidden while a recording session is actively in progress.
- **FR-011**: Attempting to save a conversation with an empty transcript (no speech captured) MUST be prevented with a clear message to the user.
- **FR-012**: The History screen MUST show an appropriate empty-state message when no conversations have been saved.

### Key Entities *(include if feature involves data)*

- **Conversation**: A saved session record. Contains: unique identifier, English transcript text (full), Spanish translation text (full), date/time saved, and a derived short preview of the English text.
- **ConversationStore**: The persistent container that holds all saved Conversation records and exposes them ordered by date for display.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: A session of 15 continuous minutes produces uninterrupted transcription and translation output — no freeze or silent stop occurs.
- **SC-002**: A conversation is saved and retrievable within 2 seconds of the user tapping "Save".
- **SC-003**: The History list loads and renders all saved records within 1 second on first open, even with 50+ saved conversations.
- **SC-004**: The detail view renders both panels immediately upon navigation with no perceptible delay.
- **SC-005**: The share sheet is presented within 1 second of tapping "Export".
- **SC-006**: 100% of saved conversations are retrievable after app force-quit and relaunch (no data loss on normal termination).
- **SC-007**: The export content received by Mail or other destinations contains both the full English transcript and the full Spanish translation in readable form.

## Assumptions

- The fix for the pipeline freeze will be investigated at the code level (likely related to `AsyncStream` exhaustion, `Task` cancellation, or `SFSpeechRecognizer` timeout); no new third-party dependency is required.
- "Save" is a user-initiated action — the app does not auto-save sessions.
- Local persistence only; no cloud sync or remote backup is in scope.
- The share/export format is plain text (not PDF or other rich format) — both English and Spanish blocks are separated by a clear label in the shared content.
- The app already handles the English/Spanish split in `LiveTranscriptionView`; the saved data will reuse the same content already held in `TranscriptionViewModel`.
- Deletion of individual saved conversations is out of scope for this feature (can be added in a future iteration).
- The History screen is a new top-level destination in the app's navigation; exact placement (tab bar, navigation link from main screen, etc.) is a UI detail resolved during implementation.
- All persistence is on-device and does not require user authentication or account management.
