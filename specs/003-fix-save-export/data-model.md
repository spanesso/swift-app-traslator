# Data Model: Fix Pipeline Freeze, Conversation History & Export

**Feature**: 003-fix-save-export  
**Date**: 2026-06-02

---

## Existing Entities (unchanged)

### SpeechSegment
Value type (struct). Carries a single ASR update through the pipeline.

| Field | Type | Description |
|-------|------|-------------|
| `text` | `String` | Full cumulative transcription text from ASR |
| `isFinal` | `Bool` | Whether ASR has finalized this utterance |
| `confidence` | `Float` | Average confidence across segments (0.0–1.0) |

### TranslatorState
Enum. Represents the app-level pipeline state.

| Case | Meaning |
|------|---------|
| `idle` | No active operation |
| `inFlight` | Translation request pending |
| `error` | Generic ASR/audio error |
| `permissionDenied` | Microphone or speech recognition auth denied |
| `modelUnavailable` | Apple Translation model not downloaded |

---

## New Entities

### ConversationEntity (Domain layer — pure struct)

Value type representing a saved conversation. Used by use cases and passed to the presentation layer. No SwiftData or framework imports.

| Field | Type | Description |
|-------|------|-------------|
| `id` | `UUID` | Stable identifier |
| `englishText` | `String` | Full English transcript (phrases joined by space) |
| `spanishText` | `String` | Full Spanish translation (sentences joined by newline) |
| `savedAt` | `Date` | Timestamp when the user tapped Save |
| `preview` | `String` (computed) | First 100 characters of `englishText`, used in list rows |

**Validation rules**:
- `englishText` must be non-empty (FR-011: block save if empty)
- `spanishText` may be empty if translation had not started when Save was tapped (store whatever is available)
- `savedAt` is set to `Date()` at save time

**State transitions**: None — `ConversationEntity` is immutable after creation.

---

### ConversationRecord (Data layer — `@Model` class)

Persistent storage model backed by SwiftData. Lives in `Data/Models/`. Maps 1:1 to `ConversationEntity`.

| Field | Type | SwiftData attribute | Description |
|-------|------|---------------------|-------------|
| `id` | `UUID` | `@Attribute(.unique)` | Primary key |
| `englishText` | `String` | — | Full English transcript |
| `spanishText` | `String` | — | Full Spanish translation |
| `savedAt` | `Date` | indexed | Sort key for ordered fetch |

**Mapping**:
- `ConversationEntity → ConversationRecord`: performed in `ConversationRepository.save()`
- `ConversationRecord → ConversationEntity`: performed in `ConversationRepository.fetchAll()`

**Fetch order**: `savedAt` descending (newest first) — FR-005.

---

## New Protocols

### ConversationRepositoryProtocol (Domain layer)

```
func save(_ conversation: ConversationEntity) async throws
func fetchAll() async throws -> [ConversationEntity]
```

No SwiftData imports. Implementations live in the Data layer.

---

## ViewModel State Additions

### TranscriptionViewModel (additions only)

| New property | Type | Purpose |
|--------------|------|---------|
| `canSave` | `Bool` (computed) | `!isRecording && !emittedPhrases.isEmpty` |
| `saveConversation()` | `async` method | Assembles EN/ES text, calls `SaveConversationUseCase` |
| `exportText` | `String` (computed) | Formatted string for `ShareLink` |

### ConversationHistoryViewModel (new)

| Property | Type | Description |
|----------|------|-------------|
| `conversations` | `[ConversationEntity]` | Ordered list of saved records |
| `isLoading` | `Bool` | True while fetching from store |
| `errorMessage` | `String?` | Non-nil if fetch/save failed |

| Method | Description |
|--------|-------------|
| `loadConversations() async` | Calls `FetchConversationsUseCase`, updates `conversations` |
| `delete(_ conversation: ConversationEntity) async` | Out of scope for this feature |
