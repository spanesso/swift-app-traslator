# Phase 1 Data Model: Preserve Full Conversation History

This feature does not introduce new persisted types. It changes the *lifecycle rules* of
existing in-memory Presentation-layer state. The entities below are the ones the fix touches.

## Entity: Captured Phrase (EN)

- **Representation**: `String` element of `TranscriptionViewModel.emittedPhrases: [String]`.
- **Identity in session**: also tracked in `emittedPhraseSet: Set<String>` for O(1) duplicate
  suppression (unchanged).
- **Ordering**: append-only, chronological (earliest at index 0).
- **Lifecycle rule (CHANGED)**:
  - Before: appended on commit, then `removeFirst()` when `count > 50`.
  - After: appended on commit; **never trimmed** during an active session.
- **Cleared when**: user starts a **new** (non-continuing) session (`startRecording(preservingSession: false)`).
- **Preserved when**: listener restarts within a session (`preservingSession: true`).

## Entity: Translated Sentence (ES)

- **Representation**: `TranslationEntry` element of
  `TranscriptionViewModel.translatedSentences: [TranslationEntry]`, where
  `TranslationEntry = { text: String, minSourceConfidence: Float }`.
- **Ordering**: append-only, chronological.
- **Lifecycle rule (CHANGED)**:
  - Before: appended in `appendTranslation`, then `removeFirst()` when `count > 30`.
  - After: appended; **never trimmed** during an active session.
- **Duplicate suppression (UNCHANGED)**: `appendTranslation` still drops a sentence that equals,
  contains, or is contained by an existing entry.
- **Cleared / preserved**: same rules as Captured Phrase.

## Entity: Session History (derived)

- **Definition**: the ordered pair (`emittedPhrases`, `translatedSentences`) for the current
  recording session.
- **Invariants after fix**:
  - I1. No committed phrase or sentence is removed while `isRecording == true` (FR-003, FR-004).
  - I2. Order is stable and append-only; existing indices never reassigned to different content
    (enables stable `ForEach` offset IDs — see research R3).
  - I3. History survives internal restart (FR-005); cleared only on explicit new session (FR-006).
  - I4. `exportText` / `saveConversation()` serialize the entire history (FR-007).

## Derived / hot-path state (NEW, internal)

- **Committed prefix cache**: cached `String` (joined `emittedPhrases`) + cached word count,
  used by the raw-stream loop to strip the committed prefix from `currentBuffer`.
  - **Invalidation**: recomputed only when `emittedPhrases` changes (on commit), not per raw
    partial (research R4). Purely an internal optimization; no observable contract change.

## Removed constants

- `private let maxEmitted = 50` — removed (or repurposed; see contract note: no cap).
- `private let maxTranslated = 30` — removed.

## Non-goals (unchanged state)

- `currentBuffer`, `latestSegmentConfidence`, `translatorState`, download/model state,
  `enginePreference`, and all Domain/Data types are unaffected.
