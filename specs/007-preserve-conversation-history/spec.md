# Feature Specification: Preserve Full Conversation History

**Feature Branch**: `007-preserve-conversation-history`  
**Created**: 2026-07-22  
**Status**: Draft  
**Input**: User description: "tenemos un problema muy grave con la app, al momento de estar escuchando la conversacion va mostrando el texto y la traduccion pero despues de un rato, cuando quiero ver lo que se hablo al inicio de la conversacion, subo con el scroll y solo encuentro poco texto, parece que no conserva toda la conversacion, necesito que encuentres este error y lo corrijas de la manera mas profesional posible sin dañar nada mas por favor."

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Read back the entire conversation during a long session (Priority: P1)

While the app is actively listening and transcribing/translating a long conversation, the user scrolls back up in either the original-language pane or the translated pane to re-read what was said near the beginning of the session. The user expects to find every phrase that was captured since recording started, in order, with nothing missing.

**Why this priority**: This is the reported defect and the core promise of the product. A live transcription/translation tool that silently discards the earlier part of the conversation is not trustworthy for its primary use (following and reviewing a spoken session end to end). Losing the beginning of a session can make the whole feature unusable.

**Independent Test**: Start recording, speak (or play) enough distinct content to exceed several dozen phrases, then scroll to the top of each pane and confirm the very first phrases captured are still present and in order.

**Acceptance Scenarios**:

1. **Given** a recording session that has captured many phrases over a long period, **When** the user scrolls to the top of the original-language pane, **Then** the first phrase captured at the start of the session is still visible and no earlier content has been removed.
2. **Given** the same session, **When** the user scrolls to the top of the translated pane, **Then** the first translated sentence of the session is still visible and in its original order.
3. **Given** an ongoing session, **When** new phrases continue to arrive, **Then** newly captured phrases are appended without displacing or deleting any previously captured phrase.
4. **Given** a long session, **When** the user stops recording and saves/exports the conversation, **Then** the saved/exported content contains the complete conversation from the first phrase to the last.

---

### User Story 2 - Auto-scroll stays on the latest line without hiding history (Priority: P2)

While listening, the newest phrase and its translation remain in view at the bottom of each pane (the live "follow" behavior), but this convenience must never come at the cost of removing older content. The user can scroll up to inspect history and, when they return to the bottom, continue following the live output.

**Why this priority**: The existing live-follow behavior is valuable and must be preserved; the fix must not regress it. This clarifies that "keep everything" and "auto-follow the newest" coexist.

**Independent Test**: During an active session, scroll up to review earlier content, confirm it is intact, then scroll back to the bottom and confirm the newest phrase is shown and auto-follow resumes.

**Acceptance Scenarios**:

1. **Given** an active session at the bottom of a pane, **When** a new phrase arrives, **Then** the view follows to show the newest phrase.
2. **Given** the user has scrolled up to read earlier history, **When** they scroll back to the bottom, **Then** the full history above remains intact and the latest phrase is visible.

---

### Edge Cases

- **Very long sessions**: A session may run for a long time (e.g., an hour-long spoken session) and accumulate a large number of phrases. The full history must remain available for scrolling for the duration of that session without content being silently dropped.
- **Restart within a session**: If the underlying listener restarts mid-session (recovery/continuity), phrases already captured before the restart must remain in the history and not be cleared.
- **Starting a new session**: When the user begins a brand-new recording (not a continuation), it is acceptable and expected that the previous session's live panes are cleared to start fresh. The prior conversation is preserved only if it was saved/exported.
- **Duplicate suppression**: The system already avoids showing duplicate/contained phrases; this de-duplication must not be confused with — or cause — loss of legitimately distinct earlier content.
- **Performance under large history**: As history grows, scrolling and live updates must remain responsive enough to keep following the conversation.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The system MUST retain every distinct captured phrase (original language) for the entire duration of an active recording session, so the user can scroll back to the first phrase at any time.
- **FR-002**: The system MUST retain every distinct translated sentence for the entire duration of an active recording session, in the order it was produced.
- **FR-003**: The system MUST NOT silently discard, truncate, or drop the oldest transcribed or translated content while a session is ongoing.
- **FR-004**: Newly captured phrases and translations MUST be appended to the existing history without removing or reordering previously captured content.
- **FR-005**: When the listener restarts within a continuing session, the system MUST preserve all history captured before the restart.
- **FR-006**: The system MUST clear the live panes only when the user explicitly starts a new (non-continuing) recording session.
- **FR-007**: The saved/exported conversation MUST include the complete history of the session, from the first captured phrase to the last, with no omissions caused by history being trimmed during capture.
- **FR-008**: The system MUST preserve the existing live auto-follow behavior (the newest phrase/translation remains visible at the bottom) without conflicting with full-history retention.
- **FR-009**: The system MUST keep the interface responsive while the retained history grows over the course of a long session.

### Key Entities *(include if feature involves data)*

- **Captured Phrase (original language)**: A committed unit of transcribed speech in the source language, displayed in the original-language pane and part of the ordered session history.
- **Translated Sentence**: A committed unit of translated text corresponding to captured speech, displayed in the translated pane and part of the ordered session history.
- **Session History**: The ordered, append-only collection of all captured phrases and translated sentences for the current recording session, from session start until the session ends or a new session begins.

## Success Criteria *(mandatory)*

### Measurable Outcomes

- **SC-001**: In a session that captures at least 100 distinct phrases, the user can scroll to the top of each pane and find the first phrase of the session still present — 100% of earlier content is retained.
- **SC-002**: Across a continuous session of at least 30 minutes of active speech, no captured phrase or translated sentence that was displayed is later removed from the history.
- **SC-003**: The saved/exported transcript of a long session contains the same number of phrases that were captured during the session (no shortfall attributable to in-session trimming).
- **SC-004**: Live auto-follow continues to show the newest phrase within a short, unchanged delay after it is produced, with no regression versus current behavior.
- **SC-005**: Scrolling through the full history of a long session remains smooth enough that the user can navigate from the newest content to the first phrase without the app becoming unresponsive.

## Assumptions

- The reported loss of early conversation is caused by an in-session cap on how many phrases/sentences are kept (oldest entries being dropped once a limit is reached), not by the speech engine failing to capture them.
- "Conserve the whole conversation" is scoped to a single active recording session (the live panes). Persisting history across app restarts or crashes is out of scope and already served by the existing Save/Export capability.
- The volume of text produced by spoken conversation is small enough that retaining a full session in memory is acceptable for the app's target sessions; extreme multi-hour sessions are handled gracefully (responsiveness maintained) rather than by silently discarding content.
- Existing behaviors — duplicate suppression, confidence-based styling, auto-scroll, restart/continuity, and save/export — must remain functional and unchanged except where they currently cause history loss.
- Target platform is iOS (per the current feature line of work); the fix applies to the live transcription/translation screen.
