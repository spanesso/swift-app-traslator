# Research: Fix Pipeline Freeze, Conversation History & Export

**Feature**: 003-fix-save-export  
**Date**: 2026-06-02  
**Status**: Complete — all unknowns resolved

---

## Decision 1: Root Cause of the Pipeline Freeze

**Decision**: The freeze is caused by `SFSpeechRecognizer`'s built-in session time limit (~60 seconds on macOS/iOS). The fix is automatic session restart within `ContinuousSpeechListener`.

**Rationale**:  
`SFSpeechRecognizer` imposes a hard session limit. When it is reached, the recognition task callback fires with `result.isFinal = true` and a non-nil `error`. The current `handleError()` function calls `finishStream()` (which terminates the `AsyncStream` continuation permanently) and `stopAudio()`. This causes:
1. The `sourceStream` in `TranscribeAudioUseCase.pumpTask` to end (for-await exits)
2. Both `rawCont` and `segCont` to be finished by the pump
3. The ViewModel's `for await sentence in stableStream` loop to exit cleanly
4. `transcriptionTask` to complete without ever setting `isRecording = false`

Result: UI shows recording is still active, but no new speech or translation appears.

**Fix strategy**:  
When the recognition callback fires with `isFinal` or error AND `!isFinished` (i.e., not from a user-initiated `stop()`), restart only the recognition layer:
1. Cancel and nil the old `recognitionTask`
2. End audio and nil the old `recognitionRequest`
3. Remove the old input tap (`inputNode.removeTap(onBus: 0)`)
4. Create a new `SFSpeechAudioBufferRecognitionRequest`
5. Install a new tap pointing to the new request
6. Start a new recognition task

The `AVAudioEngine` continues running across restarts. The `AsyncStream.Continuation` remains the same — downstream consumers (`TranscribeAudioUseCase` pump, NLP segmenter, ViewModel) see no interruption.

**Alternatives considered**:
- Restarting the full audio engine: Unnecessary overhead; the engine itself is healthy. Only the recognition request/task needs recycling.
- Increasing session duration via AVAudioSession: Not possible; Apple's limit is enforced by the Speech framework, not AVAudioSession.
- Restarting from the ViewModel/UseCase layer: Would require finishing and re-creating the stream, losing in-flight translation context. The actor-level restart is cleaner.

---

## Decision 2: SwiftData Model Placement

**Decision**: `@Model ConversationRecord` lives in the **Data layer** (`Data/Models/`). The **Domain layer** defines a pure `ConversationEntity` struct and a `ConversationRepositoryProtocol`. Use cases operate on `ConversationEntity`.

**Rationale**:  
SwiftData's `@Model` macro requires importing `SwiftData`, which violates the Domain layer purity rule (Domain imports only Foundation/CoreGraphics/simd/CoreMedia). Separating the model from the entity also insulates the rest of the app from SwiftData's macro-generated code and makes use cases independently testable.

**Alternatives considered**:
- `@Model` class in Domain layer: Violates Domain purity rule explicitly stated in CLAUDE.md.
- CoreData: More boilerplate for a simple two-field model. SwiftData is the modern Apple replacement and the project already targets macOS 14+.
- In-memory persistence only: Does not meet FR-003 (survives app termination).

---

## Decision 3: ModelContainer Ownership

**Decision**: The `ModelContainer` is created in `DependencyContainer.init()` and exposed so `TranslatorAppApp` can pass it to `.modelContainer()`.

**Rationale**:  
`DependencyContainer` is the composition root. Owning the container there keeps all dependency wiring in one place. `ConversationRepository` receives `ModelContainer.mainContext` in its initializer. The app entry point just registers the already-created container with SwiftUI's environment.

**Alternatives considered**:
- Creating `ModelContainer` in `TranslatorAppApp` and injecting `ModelContext` via SwiftUI environment: Breaks Clean Architecture — the Data layer would have to receive its dependency from the SwiftUI environment, coupling it to SwiftUI.
- Singleton `ModelContainer`: Violates the no-global-state rule stated in CLAUDE.md.

---

## Decision 4: Export Mechanism

**Decision**: Use SwiftUI `ShareLink` with a formatted `String` item. No additional framework.

**Rationale**:  
The app already targets macOS 13+ (required by the Translation framework). `ShareLink` is available from macOS 13 / iOS 16. It surfaces the native share sheet, which includes Mail as a destination — satisfying both the email requirement (FR-009) and other sharing scenarios (Messages, AirDrop, Files). The export content is plain text with clear EN/ES section labels.

**Export format**:
```
=== ENGLISH TRANSCRIPT ===

{full English text, phrases joined by newlines}

=== SPANISH TRANSLATION ===

{full Spanish text, sentences joined by newlines}
```

**Alternatives considered**:
- `MFMailComposeViewController` (UIKit): Not available on macOS. Requires UIKit import.
- `NSSharingServicePicker` (AppKit): Available on macOS but bypasses SwiftUI; unnecessary given ShareLink exists.
- PDF export: Adds complexity with no user requirement for formatted output.

---

## Decision 5: Navigation Structure

**Decision**: Wrap `LiveTranscriptionView` in a `NavigationStack`. Add a toolbar button (history icon) that navigates to `ConversationHistoryView`. History detail (`ConversationDetailView`) is pushed onto the stack from the list.

**Rationale**:  
The existing app has no navigation wrapper. `NavigationStack` is the modern SwiftUI API (macOS 13+). A toolbar button is the macOS-native pattern for accessing a secondary view. This requires minimal structural change to the existing `LiveTranscriptionView`.

**Alternatives considered**:
- `TabView`: Appropriate for peer-level top-level destinations; history is a secondary destination, not peer.
- Sheet presentation: Modals are appropriate for transient content; a persistent history list warrants push navigation.
- `NavigationSplitView`: Well-suited for macOS but would require significant rework of the existing full-screen layout.

---

## Decision 6: Save Action Trigger

**Decision**: Save is a user-initiated button in `LiveTranscriptionView`, visible only when `!isRecording && hasContent`. The ViewModel assembles full text from `emittedPhrases` (EN) and `translatedSentences` (ES) and calls the save use case.

**Rationale**:  
Per the spec, Save is always user-initiated (FR-002, Assumption: "auto-save is out of scope"). The ViewModel already holds all session content. Assembling it at save time avoids any intermediate storage.

**What "full text" means**:
- **English**: `emittedPhrases.joined(separator: " ")` — all committed phrases, space-delimited
- **Spanish**: `translatedSentences.joined(separator: "\n")` — each translated sentence on its own line
- If recording ended before any phrases were committed, both would be empty and Save is blocked (FR-011)

---

## Decision 7: ConversationHistoryViewModel Ownership

**Decision**: `ConversationHistoryViewModel` is created by `DependencyContainer` and passed to `ConversationHistoryView` as an `@ObservedObject` (or plain init parameter since it uses `@Observable`).

**Rationale**:  
Consistent with the existing MVVM rule: "ViewModels are owned ONLY by `TranslatorAppApp` via `@StateObject`". The history VM is created once in the container and held for the session.
