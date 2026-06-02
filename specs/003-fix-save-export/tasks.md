# Tasks: Fix Pipeline Freeze, Conversation History & Export

**Input**: Design documents from `specs/003-fix-save-export/`
**Prerequisites**: plan.md ✅ · spec.md ✅ · research.md ✅ · data-model.md ✅
**Tests**: Not requested — no test tasks generated.

**Organization**: Tasks are grouped by user story (US1–US4) to enable independent implementation and testing.

## Format: `[ID] [P?] [Story] Description`

- **[P]**: Can run in parallel (different files, no conflicting dependencies)
- **[Story]**: Which user story this task belongs to (US1–US4)
- All paths relative to `TranslatorApp/`

---

## Phase 1: Setup

**Purpose**: Ensure Xcode project is ready for new files.

- [x] T001 Confirm `SwiftData` framework is auto-linked in the TranslatorApp target (Xcode → target → Frameworks; it should appear automatically on macOS 14+). No new build settings or targets are needed. All new `.swift` files created in subsequent tasks must be added to the **TranslatorApp** target in Xcode when created.

**Checkpoint**: Project structure confirmed, ready for implementation.

---

## Phase 2: Foundational (Blocking Prerequisites)

**Purpose**: Domain entities, repository protocol, and SwiftData model that ALL user stories depend on.

**⚠️ CRITICAL**: No US2–US4 work can begin until T002–T005 are complete. US1 (freeze fix) is independent and can be done in parallel.

- [x] T002 [P] Create `ConversationEntity` pure value type in `Domain/Entities/ConversationEntity.swift`. This is a plain `struct` (no framework imports beyond Foundation): `id: UUID`, `englishText: String`, `spanishText: String`, `savedAt: Date`, and a computed `var preview: String` that returns the first 100 characters of `englishText` (trimmed), or `"(no transcript)"` if empty.

- [x] T003 [P] Create `ConversationRepositoryProtocol` in `Domain/Interfaces/ConversationRepositoryProtocol.swift`. Two methods only: `func save(_ conversation: ConversationEntity) async throws` and `func fetchAll() async throws -> [ConversationEntity]`. No imports beyond Foundation.

- [x] T004 [P] Create `ConversationRecord` SwiftData model in `Data/Models/ConversationRecord.swift`. Import SwiftData and Foundation. Annotate the class `@Model final class ConversationRecord`. Fields: `@Attribute(.unique) var id: UUID`, `var englishText: String`, `var spanishText: String`, `var savedAt: Date`. Add a memberwise `init` and a `func toEntity() -> ConversationEntity` helper that maps fields to `ConversationEntity`.

- [x] T005 Create `ConversationRepository` in `Data/Repositories/ConversationRepository.swift`. Import SwiftData and Foundation. Implement `ConversationRepositoryProtocol`. Store a `private let context: ModelContext` injected via init. `save(_:)`: map entity to `ConversationRecord`, `context.insert(record)`, `try context.save()`. `fetchAll()`: build a `FetchDescriptor<ConversationRecord>(sortBy: [SortDescriptor(\.savedAt, order: .reverse)])`, fetch, and return mapped entities via `toEntity()`. (Depends on T002, T003, T004)

**Checkpoint**: Domain + Data persistence layer is complete. Use cases and ViewModels can now be built on top.

---

## Phase 3: User Story 1 — Sustained Long Session (Priority: P1) 🎯 MVP

**Goal**: Fix the pipeline freeze that silently stops transcription after ~1 minute.

**Independent Test**: Start recording, speak continuously for 5–10 minutes; verify transcription and translation keep updating without any restart.

- [x] T006 [US1] Fix `ContinuousSpeechListener` in `Data/ContinuousSpeechListener.swift`.

  **Add** a private `restartRecognition(sessionId: String)` method that:
  1. Calls `recognitionTask?.cancel()` and sets `recognitionTask = nil`
  2. Calls `recognitionRequest?.endAudio()` and sets `recognitionRequest = nil`
  3. Calls `audioEngine.inputNode.removeTap(onBus: 0)` — does **NOT** stop the audio engine
  4. Calls `try? setupRecognition(sessionId: sessionId)` to install a new request + task

  **Modify** the recognition callback closure inside `setupRecognition(sessionId:)`. Find the block:
  ```swift
  if error != nil {
      self.logger.error("❌ [Speech] Recognition error: \(String(describing: error))")
      await self.handleError()
  }
  ```
  Replace with:
  ```swift
  if result?.isFinal == true || error != nil {
      if await self.isFinished {
          // user-initiated stop: stream already closed, do nothing
      } else {
          // system-initiated end (SFSpeechRecognizer timeout): restart transparently
          self.logger.info("🔄 [Speech] Recognition session ended — restarting for session \(sessionId)")
          await self.restartRecognition(sessionId: sessionId)
      }
  }
  ```
  The `isFinished` flag is already set to `true` by `finishStream()` which is called from `stop()`, so this correctly distinguishes user-initiated stop from system timeout.

  **Log** the restart count by adding `private var restartCount: Int = 0` and incrementing it in `restartRecognition`, logging: `"🔄 [Speech] Restart #\(restartCount)"`.

**Checkpoint**: Sessions run indefinitely. Transcription and translation continue past the 1-minute mark.

---

## Phase 4: User Story 2 — Save a Completed Conversation (Priority: P2)

**Goal**: After recording ends, the user can tap Save to persist the full EN + ES session to local storage.

**Independent Test**: Complete a short session, tap Save, force-quit the app, reopen — saved record appears in history.

- [x] T007 [P] [US2] Create `SaveConversationUseCase` in `Domain/UseCases/SaveConversationUseCase.swift`.

  Add `enum ConversationError: Error { case emptyTranscript }` in this file.

  The use case `final class SaveConversationUseCase`:
  - Init: `init(repository: ConversationRepositoryProtocol)`
  - `func execute(englishText: String, spanishText: String) async throws`:
    - Guard that `englishText.trimmingCharacters(in: .whitespaces)` is non-empty; otherwise `throw ConversationError.emptyTranscript`
    - Build `ConversationEntity(id: UUID(), englishText: englishText, spanishText: spanishText, savedAt: Date())`
    - Call `try await repository.save(entity)`

  (Depends on T002, T003)

- [x] T008 [US2] Modify `TranscriptionViewModel` in `Presentation/ViewModels/TranscriptionViewModel.swift`.

  **Add** private stored property: `private let saveConversationUseCase: SaveConversationUseCase`
  **Update** `init` to accept `saveConversationUseCase: SaveConversationUseCase` and assign it.
  **Add** the following computed and stored properties:
  ```swift
  var canSave: Bool { !isRecording && !emittedPhrases.isEmpty }
  var isSaving: Bool = false
  var savedSuccessfully: Bool = false
  ```
  **Add** `var exportText: String` computed property that returns:
  ```
  === ENGLISH TRANSCRIPT ===

  {emittedPhrases.joined(separator: " ")}

  === SPANISH TRANSLATION ===

  {translatedSentences.joined(separator: "\n")}
  ```

  **Add** `func saveConversation() async`:
  ```swift
  guard canSave, !isSaving else { return }
  isSaving = true
  defer { isSaving = false }
  do {
      try await saveConversationUseCase.execute(
          englishText: emittedPhrases.joined(separator: " "),
          spanishText: translatedSentences.joined(separator: "\n")
      )
      savedSuccessfully = true
      try? await Task.sleep(nanoseconds: 2_000_000_000) // reset feedback after 2s
      savedSuccessfully = false
  } catch ConversationError.emptyTranscript {
      errorMessage = "Nothing to save — no speech was captured."
      hasError = true
  } catch {
      errorMessage = "Save failed: \(error.localizedDescription)"
      hasError = true
  }
  ```

  (Depends on T007)

- [x] T009 [US2] Add Save button to `LiveTranscriptionView.swift` in `Presentation/Views/LiveTranscriptionView.swift`.

  Inside the `VStack(spacing: 12)` that already contains `RecordButton`, add below it:
  ```swift
  if viewModel.canSave {
      Button {
          Task { await viewModel.saveConversation() }
      } label: {
          Label(viewModel.savedSuccessfully ? "Saved!" : "Save",
                systemImage: viewModel.savedSuccessfully ? "checkmark.circle.fill" : "square.and.arrow.down")
      }
      .disabled(viewModel.isSaving)
      .buttonStyle(.borderedProminent)
      .tint(viewModel.savedSuccessfully ? .green : .blue)
  }
  ```

  (Depends on T008)

**Checkpoint**: After a session ends, tap Save; verify data persists across app restarts.

---

## Phase 5: User Story 3 — Browse & Read Saved Conversations (Priority: P2)

**Goal**: A History screen lists all saved sessions; tapping one opens a split-pane EN/ES detail view.

**Independent Test**: Save two conversations with different content; navigate to History; verify both appear; tap each and verify correct EN/ES split content is shown.

- [x] T010 [P] [US3] Create `FetchConversationsUseCase` in `Domain/UseCases/FetchConversationsUseCase.swift`.

  `final class FetchConversationsUseCase`:
  - Init: `init(repository: ConversationRepositoryProtocol)`
  - `func execute() async throws -> [ConversationEntity]`: delegates to `try await repository.fetchAll()`

  (Depends on T002, T003)

- [x] T011 [US3] Create `ConversationHistoryViewModel` in `Presentation/ViewModels/ConversationHistoryViewModel.swift`.

  ```swift
  @MainActor
  @Observable
  final class ConversationHistoryViewModel {
      var conversations: [ConversationEntity] = []
      var isLoading: Bool = false
      var errorMessage: String? = nil

      private let fetchUseCase: FetchConversationsUseCase

      init(fetchUseCase: FetchConversationsUseCase) {
          self.fetchUseCase = fetchUseCase
      }

      func loadConversations() async {
          isLoading = true
          defer { isLoading = false }
          do {
              conversations = try await fetchUseCase.execute()
          } catch {
              errorMessage = "Could not load conversations: \(error.localizedDescription)"
          }
      }
  }
  ```

  (Depends on T010)

- [x] T012 [US3] Create `ConversationHistoryView` in `Presentation/Views/ConversationHistoryView.swift`.

  A SwiftUI `struct ConversationHistoryView: View` that takes `var viewModel: ConversationHistoryViewModel` as an init parameter (no `@StateObject`).

  Body:
  - `NavigationStack` wrapping a `List`:
    - For each conversation: `NavigationLink(destination: ConversationDetailView(conversation: conversation))` with a row showing date (formatted `"MMM d, yyyy — HH:mm"`) and `conversation.preview` truncated with `.lineLimit(2)`
    - Empty state: `ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right", description: Text("Saved conversations will appear here."))` (macOS 13+ API) or a centered `Text("No saved conversations yet.")` as fallback
  - `.task { await viewModel.loadConversations() }` modifier
  - `ProgressView()` overlay when `viewModel.isLoading`
  - `.navigationTitle("Conversation History")`
  - `.preferredColorScheme(.dark)`

  (Depends on T011; references T013)

- [x] T013 [US3] Create `ConversationDetailView` in `Presentation/Views/ConversationDetailView.swift`.

  A SwiftUI `struct ConversationDetailView: View` that takes `let conversation: ConversationEntity` (value, no VM).

  Body (mirrors `LiveTranscriptionView` proportions):
  ```
  GeometryReader { geometry in
      HStack(spacing: 0) {
          // Left panel — 50% width
          VStack(alignment: .leading) {
              headerView(title: "ENGLISH TRANSCRIPT", icon: "text.bubble.fill", color: .yellow)
              ScrollView { Text(conversation.englishText).font(.system(size: 13, design: .monospaced)).padding() }
          }
          .frame(width: geometry.size.width * 0.5)
          .background(Color(white: 0.12))

          Divider().background(Color.gray.opacity(0.3))

          // Right panel — 50% width
          VStack(alignment: .leading) {
              headerView(title: "TRADUCCIÓN (ES)", icon: "character.bubble.fill", color: .blue)
              ScrollView { Text(conversation.spanishText).font(.system(size: 14)).padding() }
          }
          .frame(width: geometry.size.width * 0.5)
          .background(Color(white: 0.08))
      }
  }
  ```

  Add a `headerView(title:icon:color:)` private helper (same signature as the one in `LiveTranscriptionView`).
  Add `.navigationTitle(conversation.savedAt, formatted: .dateTime.month().day().year())` or a formatted string title.
  Add `.preferredColorScheme(.dark)`.
  Add toolbar item: `ShareLink(item: exportText) { Label("Export", systemImage: "square.and.arrow.up") }` where `exportText` is a private computed property building the same `=== ENGLISH ===` / `=== SPANISH ===` format as `TranscriptionViewModel.exportText`.

  (Depends on T002)

**Checkpoint**: History list shows all saved records newest-first; detail opens a correct split-pane view; export via share sheet works from detail.

---

## Phase 6: User Story 4 — Export from Live Session (Priority: P3)

**Goal**: After recording ends, the user can also export directly from the live view without going through History.

**Independent Test**: End a session; verify Export button appears in the live view; tap it; verify share sheet opens with correctly formatted EN+ES text.

- [x] T014 [P] [US4] Add Export `ShareLink` button to `LiveTranscriptionView.swift`.

  In the same `VStack(spacing: 12)` block where Save button was added (T009), add below the Save button:
  ```swift
  if viewModel.canSave {
      ShareLink(item: viewModel.exportText) {
          Label("Export", systemImage: "square.and.arrow.up")
      }
      .buttonStyle(.bordered)
  }
  ```
  `viewModel.exportText` was added in T008. Both Save and Export buttons appear only when `canSave` is true.

  (Depends on T008, T009)

**Checkpoint**: Save and Export buttons appear after a session; ShareLink triggers the native share sheet with full EN+ES content.

---

## Phase 7: Integration — Wire Everything Together

**Purpose**: Connect all new components through `DependencyContainer` and update the app entry point to add navigation and SwiftData.

- [x] T015 [US2] [US3] Update `DependencyContainer` in `App/DependencyContainer.swift`.

  **Add** new stored properties:
  ```swift
  let modelContainer: ModelContainer
  private let conversationRepository: ConversationRepository
  private let saveConversationUseCase: SaveConversationUseCase
  private let fetchConversationsUseCase: FetchConversationsUseCase
  private let historyViewModel: ConversationHistoryViewModel
  ```

  **In `init()`**, after the existing setup, add:
  ```swift
  self.modelContainer = try! ModelContainer(for: ConversationRecord.self)
  let convRepo = ConversationRepository(context: modelContainer.mainContext)
  self.conversationRepository = convRepo
  self.saveConversationUseCase = SaveConversationUseCase(repository: convRepo)
  self.fetchConversationsUseCase = FetchConversationsUseCase(repository: convRepo)
  self.historyViewModel = ConversationHistoryViewModel(fetchUseCase: fetchConversationsUseCase)
  ```

  **Update** `self.viewModel` construction to pass the new use case:
  ```swift
  self.viewModel = TranscriptionViewModel(
      transcribeUseCase: transcribeUseCase,
      saveConversationUseCase: saveConversationUseCase
  )
  ```

  **Add** factory method:
  ```swift
  @MainActor
  func makeHistoryViewModel() -> ConversationHistoryViewModel { historyViewModel }
  ```

  (Depends on T004, T005, T007, T010, T008, T011)

- [x] T016 [US2] [US3] Update `TranslatorAppApp.swift` in `App/TranslatorAppApp.swift`.

  Wrap the existing `LiveTranscriptionView` in a `NavigationStack`. Register the SwiftData container. Expose history view model:

  ```swift
  var body: some Scene {
      WindowGroup {
          NavigationStack {
              LiveTranscriptionView(viewModel: container.makeTranscriptionViewModel(),
                                   historyViewModel: container.makeHistoryViewModel())
          }
          .modelContainer(container.modelContainer)
      }
  }
  ```

  If `LiveTranscriptionView` does not yet accept `historyViewModel` as a parameter, add it now (see T017).

  (Depends on T015)

- [x] T017 [US3] Add history navigation to `LiveTranscriptionView.swift`.

  **Update** `LiveTranscriptionView.init` to accept `historyViewModel: ConversationHistoryViewModel`.
  **Store** it as `var historyViewModel: ConversationHistoryViewModel`.

  **Add** a `.toolbar` modifier to the root `ZStack` (or outer `VStack`) with a trailing `ToolbarItem`:
  ```swift
  .toolbar {
      ToolbarItem(placement: .automatic) {
          NavigationLink(destination: ConversationHistoryView(viewModel: historyViewModel)) {
              Image(systemName: "clock.arrow.circlepath")
          }
      }
  }
  ```

  The `NavigationLink` works because `LiveTranscriptionView` is now inside a `NavigationStack` (set up in T016).

  (Depends on T016, T012)

**Checkpoint**: Full integration complete. App launches with NavigationStack; Save/Export buttons appear after recording; History accessible from toolbar; detail view opens from list.

---

## Phase 8: Polish & Cross-Cutting Concerns

- [x] T018 Audit all new and modified Swift files for the 250-line limit (CLAUDE.md rule). Files to check: `ContinuousSpeechListener.swift`, `TranscriptionViewModel.swift`, `LiveTranscriptionView.swift`, `ConversationHistoryView.swift`, `ConversationDetailView.swift`, `DependencyContainer.swift`. If any exceeds 250 lines, extract logical subviews or helpers into a new file.

- [x] T019 Add `OSLog` loggers to new files that perform meaningful operations. Use subsystem `com.spanesso.TraslatorApp`. Suggested categories: `"Persistence"` for `ConversationRepository`, `"History"` for `ConversationHistoryViewModel`. Log save and fetch operations at `.info` level; errors at `.error` level.

- [x] T020 Build the project (`xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' build`) and resolve any Swift 6 strict concurrency warnings. Common issues: `ConversationRepository` accessing `ModelContext` off MainActor (ensure it is called from MainActor context), `@Sendable` closures capturing `ConversationEntity`. Do not use `@unchecked Sendable` — fix the root cause.

---

## Dependencies & Execution Order

### Phase Dependencies

- **Phase 1 (Setup)**: No dependencies — start immediately
- **Phase 2 (Foundational)**: Depends on Phase 1 — BLOCKS US2, US3, US4
- **Phase 3 (US1)**: Independent of Phase 2 — can start immediately alongside it
- **Phase 4 (US2)**: Depends on Phase 2 (T002, T003 → T007, T008)
- **Phase 5 (US3)**: Depends on Phase 2 (T002, T003 → T010)
- **Phase 6 (US4)**: Depends on Phase 4 (T008 → T014)
- **Phase 7 (Integration)**: Depends on Phase 4, Phase 5, Phase 6
- **Phase 8 (Polish)**: Depends on Phase 7

### User Story Dependencies

| Story | Depends On | Can Be Parallel With |
|-------|-----------|---------------------|
| US1 — Freeze fix | Nothing | Everything (touches only ContinuousSpeechListener) |
| US2 — Save | Foundational (T002–T005) | US3 (different files) |
| US3 — History | Foundational (T002–T005) | US2 (different files) |
| US4 — Export (live view) | US2 (T008 for exportText) | US3 (different files) |

### Within Each Phase

- T002, T003, T004: fully parallel (different files, no shared dependencies)
- T007 and T010: parallel (different files; both depend on T002+T003 only)
- T011 and T013: parallel after their own dependencies (T010 and T002 respectively)
- T012: sequential after T011

---

## Parallel Execution Examples

### Foundational Phase (fastest path)

```
Launch simultaneously:
  Task: "T002 — Create ConversationEntity in Domain/Entities/ConversationEntity.swift"
  Task: "T003 — Create ConversationRepositoryProtocol in Domain/Interfaces/ConversationRepositoryProtocol.swift"
  Task: "T004 — Create ConversationRecord @Model in Data/Models/ConversationRecord.swift"
  Task: "T006 — Fix ContinuousSpeechListener (US1, independent)"

Then (once T002+T003+T004 done):
  Task: "T005 — Create ConversationRepository"
  Task: "T007 — Create SaveConversationUseCase"
  Task: "T010 — Create FetchConversationsUseCase"
```

### US2 + US3 in parallel (once Foundational done)

```
Developer A → US2 path: T007 → T008 → T009 → T014
Developer B → US3 path: T010 → T011 → T012 → T013

Both finish before Phase 7 (Integration).
```

---

## Implementation Strategy

### MVP (User Story 1 only — freeze fix)

1. T001 (setup check)
2. T006 (freeze fix)
3. **Stop and validate**: Record for 10 minutes, verify no freeze

### Incremental delivery

1. MVP (US1): T001 → T006 — working pipeline
2. Add US2 (Save): T002 → T003 → T004 → T005 → T007 → T008 → T009 — Save works end-to-end
3. Add US3 (History): T010 → T011 → T012 → T013 — History + Detail work
4. Add US4 (Export): T014 — Export works from live view + history detail
5. Wire up: T015 → T016 → T017 — Full app integration
6. Polish: T018 → T019 → T020

---

## Notes

- `[P]` tasks touch different files and have no shared dependencies at the time they run — safe to dispatch simultaneously
- All new `.swift` files must be added to the **TranslatorApp** target in Xcode (File Inspector → Target Membership)
- `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means non-annotated classes are implicitly `@MainActor` — new classes that should NOT be MainActor (e.g., use cases called from background) may need explicit `nonisolated` or `actor` annotation
- `ModelContext.mainContext` is MainActor-bound; `ConversationRepository` is called from the ViewModel which is `@MainActor` — this is safe
- Do not auto-save sessions; Save is always user-initiated (per spec Assumption)
- Deletion of conversations is out of scope for this feature
