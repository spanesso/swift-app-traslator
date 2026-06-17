# Tasks: Accent-Robust ASR & Intelligible Translation

**Feature**: `005-accent-robust-asr`
**Branch**: `005-accent-robust-asr`
**Spec**: [spec.md](./spec.md) | **Plan**: [plan.md](./plan.md) | **Data model**: [data-model.md](./data-model.md)
**Generated**: 2026-06-17

## Format: `[ID] [P?] [US?] Description`

- **[P]**: Can run in parallel with other [P] tasks in the same phase (different files, no incomplete deps)
- **[US#]**: User story this task belongs to
- Every task includes an exact file path

---

## Phase 1: Setup (Project Infrastructure)

**Purpose**: Configure the Xcode project to support WhisperKit, new source directories, new evaluation test target, and iOS 26+ capabilities. No Swift logic yet — scaffolding only.

- [ ] T001 Add WhisperKit SPM package to `TranslatorApp.xcodeproj`: resolve `https://github.com/argmaxinc/WhisperKit` @ v1.0.0 (`argmaxinc/argmax-oss-swift`), link to `TranslatorApp` main target only (not test targets); record the resolved commit SHA in a comment in `DependencyContainer.swift`
- [x] T002 [P] Create source directory groups in Xcode Navigator (and on disk): `TranslatorApp/Data/SpeechEngines/`, `TranslatorApp/Data/Audio/`, `TranslatorApp/Data/Correctors/`, `TranslatorApp/Data/Coordinators/`, `TranslatorApp/Presentation/Views/Settings/`
- [ ] T003 [P] Create `TranslatorAppEvaluationTests` Xcode test target (XCTest, iOS, no host app) with directory layout: `TranslatorAppEvaluationTests/Evaluation/`, `TranslatorAppEvaluationTests/Corpora/`, `TranslatorAppEvaluationTests/Tests/`, `TranslatorAppEvaluationTests/Tools/evaluation-delta/`; add scheme so it appears in `xcodebuild -scheme TranslatorApp test`
- [ ] T004 [P] Update `TranslatorApp/TranslatorApp.entitlements` — add `com.apple.developer.background-asset-downloader-extension` key (`true`) for BackgroundAssets model download; set iOS deployment target to 26.0 in `TranslatorApp.xcodeproj` build settings

**Checkpoint**: `xcodebuild -scheme TranslatorApp build` resolves WhisperKit with zero errors. New target appears in scheme. New directories exist in Xcode Navigator.

---

## Phase 2: Foundational (Domain Entities & Interfaces)

**Purpose**: Define all new value types and protocol interfaces. Every downstream adapter, service, and UI component depends on these. Nothing in Phases 3–6 can compile until this phase is complete.

**⚠️ CRITICAL**: Complete before starting any user-story phase.

- [x] T005 Create `TranslatorApp/Domain/Entities/TranscriptToken.swift` — `struct TranscriptToken: Sendable, Hashable` with fields `text: String`, `confidence: Float` (0.0–1.0), `startTime: TimeInterval?`, `endTime: TimeInterval?`, `isLocked: Bool`; `nonisolated init(...)`; import `Foundation` only; add to `TranslatorApp` target
- [x] T006 [P] Create `TranslatorApp/Domain/Entities/EngineId.swift` — `enum EngineId: String, Sendable, Codable` with four cases: `.legacyAppleSFSpeech`, `.appleSpeechAnalyzer`, `.whisperKitTurbo`, `.whisperKitSmall`; import `Foundation` only
- [x] T007 [P] Create `TranslatorApp/Domain/Entities/AccentGroup.swift` — `enum AccentGroup: String, Sendable, Codable, CaseIterable` with six cases: `.native`, `.italian`, `.indianSouthAsian`, `.latino`, `.other`, `.unknown`; import `Foundation` only
- [x] T008 [P] Create `TranslatorApp/Domain/Entities/EnginePreference.swift` — `enum EnginePreference: String, Sendable, Codable` with `.auto`, `.appleOnly`, `.whisperPreferred`; add `static func fromUserDefaults() -> EnginePreference` and `func saveToUserDefaults()` using key `"engine.preference"`; import `Foundation` only
- [x] T009 [P] Create `TranslatorApp/Domain/Entities/ModelInstallState.swift` — `enum ModelInstallState: Sendable, Equatable` with six cases from data-model.md §1.6 (`.notRequested`, `.awaitingConsent`, `.downloading(progress: Double)`, `.installed(version: String, sizeBytes: Int64)`, `.declined`, `.failed(reason: ModelInstallFailure)`); plus `enum ModelInstallFailure: Sendable, Equatable` with `.networkUnavailable`, `.deviceUnsupported`, `.insufficientStorage`, `.canceled`, `.unknown(String)`; import `Foundation` only
- [x] T010 Extend `TranslatorApp/Domain/Entities/SpeechSegment.swift` — add three new fields with defaults: `let tokens: [TranscriptToken]`, `let source: EngineId`, `let isHypothesis: Bool`; update the existing `nonisolated init(text:isFinal:confidence:)` to add `tokens: [TranscriptToken] = []`, `source: EngineId = .legacyAppleSFSpeech`, `isHypothesis: Bool = false` as trailing defaulted params; all current call sites must compile unchanged
- [x] T011 [P] Extend `TranslatorApp/Domain/Entities/TranslatorState.swift` — add two new cases: `.downloadingASRModel(progress: Double)` and `.correcting`; add `Equatable` conformance with a custom `==` that handles associated-value cases; preserve all existing cases
- [x] T012 [P] Extend (or create) `TranslatorApp/Domain/Entities/SpeechError.swift` — add `.modelUnavailable`, `.deviceUnsupported`, `.downloadFailed(String)` error cases to the existing `SpeechError` type (or a new `enum SpeechError: Error, Sendable` if the file does not exist); import `Foundation` only
- [x] T013 Create `TranslatorApp/Domain/Interfaces/SpeechEngineProtocol.swift` — copy verbatim from `specs/005-accent-robust-asr/contracts/SpeechEngineProtocol.swift`; this file is now a compile unit, so add it to the `TranslatorApp` Xcode target; verify it imports `Foundation` only
- [x] T014 [P] Create `TranslatorApp/Domain/Interfaces/TranscriptCorrectorProtocol.swift` — copy verbatim from `specs/005-accent-robust-asr/contracts/TranscriptCorrectorProtocol.swift`; add to `TranslatorApp` target
- [x] T015 [P] Create `TranslatorApp/Domain/Interfaces/ModelDownloadCoordinatorProtocol.swift` — copy verbatim from `specs/005-accent-robust-asr/contracts/ModelDownloadCoordinatorProtocol.swift`; add to `TranslatorApp` target

**Checkpoint**: `xcodebuild -scheme TranslatorApp build` after Phase 2 produces zero errors and zero Swift concurrency warnings. All new types are accessible in scope.

---

## Phase 3: User Story 1 — L2 Speaker Is Understood (Priority: P1) 🎯 MVP

**Goal**: Italian, Indian, and Latino-accented English speakers produce accurate EN transcriptions and coherent ES translations through the tiered hybrid pipeline (Tier 0 = AppleSpeechAnalyzer, Tier 1 = WhisperKit, Tier 2 = Foundation Models corrector).

**Independent Test**: Play a 10-sentence recording of an Italian- or Indian-accented speaker (real device, A17 Pro+). The EN pane text matches what was said within ≤1 substitution per sentence. The ES pane carries the intended meaning. Log shows `engineId=whisperKitTurbo`. App does not crash or produce silent output.

### Engine Adapters

- [x] T016 [P] [US1] Create `TranslatorApp/Data/SpeechEngines/LegacySFSpeechEngine.swift` — `actor LegacySFSpeechEngine: SpeechEngineProtocol`; thin wrapper over the existing `ContinuousSpeechListener` actor; `var engineId: EngineId { .legacyAppleSFSpeech }`; `func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment>` delegates to `ContinuousSpeechListener.start()` and maps its existing `AsyncStream<SpeechSegment>` unchanged (tokens empty, source `.legacyAppleSFSpeech`); `func stop() async` delegates to `ContinuousSpeechListener.stop()`; import `Foundation`, `AVFoundation`, `Speech`
- [x] T017 [P] [US1] Create `TranslatorApp/Data/Audio/VADGate.swift` — `actor VADGate`; `func filter(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<SpeechSegment>` wraps the input stream; drops any segment where `segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty` AND it follows another empty segment within 0.5 s (use `ContinuousClock` for timing); passes non-silent segments through unchanged; prevents WhisperKit silence-loop artifacts from reaching the segmenter; import `Foundation`
- [x] T018 [US1] Create `TranslatorApp/Data/SpeechEngines/AppleSpeechAnalyzerEngine.swift` — `actor AppleSpeechAnalyzerEngine: SpeechEngineProtocol`; wraps iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`; `engineId` returns `.appleSpeechAnalyzer`; maps `SFTranscriptionSegment` confidence to `TranscriptToken.confidence`; sets `isHypothesis = true` for partial results; emits `SpeechSegment` with `source: .appleSpeechAnalyzer`; handles `AVAudioSession` interruptions by calling `stop()` and emitting a `.permissionDenied` or `.error` state upstream; import `Speech`, `AVFoundation`, `Foundation`; stay under 220 lines
- [x] T019 [US1] Create `TranslatorApp/Data/SpeechEngines/WhisperKitEngine.swift` — `actor WhisperKitEngine: SpeechEngineProtocol`; wraps `WhisperKit`; `engineId` returns `.whisperKitTurbo`; on `start(options:)`: initialise `WhisperKit` with model `"large-v3-turbo"` (compressed), set `task = .transcribe`, `language = "en"`; emit hypothesis segments (`isHypothesis: true`) from the partial-result callback, confirmed segments (`isFinal: true`) from the final callback; map `WordTiming` array → `[TranscriptToken]` with `startTime`/`endTime` populated; pipe output through `VADGate.filter()`; import `WhisperKit`, `Foundation`; stay under 220 lines

### Corrector Stack

- [x] T020 [US1] Create `TranslatorApp/Data/Correctors/FoundationModelsCorrector.swift` — `actor FoundationModelsCorrector: TranscriptCorrectorProtocol`; `@available(iOS 26, *)` guarded; uses `FoundationModels.LanguageModelSession`; on `correct(segment:lockThreshold:)`: (1) lock all tokens with `confidence >= lockThreshold` by setting `isLocked = true`, (2) build a prompt instructing the model to fix grammar only within unlocked spans and never introduce new proper nouns or numerals, (3) call the model, (4) post-validate response — use `EntityExtractor` (T037) to assert no entity in output absent from input and no numeral absent from input, (5) return `.corrected(CorrectionResult)` or `.rejected(.hallucinationDetected)` as appropriate; log `[CORRECTOR]` lines via `OSLog` under category `"Corrector"`; import `FoundationModels`, `Foundation`; stay under 200 lines
- [x] T021 [P] [US1] Create `TranslatorApp/Domain/Services/TranscriptCorrectorService.swift` — `actor TranscriptCorrectorService`; owns a `TranscriptCorrectorProtocol` instance; exposes `func process(_ segment: SpeechSegment, deviceSupportsA17Pro: Bool) async -> SpeechSegment`; gate logic from data-model.md §4.2: (a) if `!deviceSupportsA17Pro` → return segment unchanged, (b) if `segment.tokens.isEmpty || min(tokens.confidence) >= 0.85` → return unchanged, (c) otherwise call `corrector.correct(segment:lockThreshold:0.85)` and return corrected or original on rejection; import `Foundation` only

### Download Coordinator

- [x] T022 [US1] Create `TranslatorApp/Data/Coordinators/BackgroundAssetsCoordinator.swift` — `actor BackgroundAssetsCoordinator: ModelDownloadCoordinatorProtocol`; wraps `BackgroundAssets.BADownloadManager`; state machine enforces only the legal transitions from data-model.md §1.6; emits `ModelInstallState` changes via an internal `AsyncStream.Continuation`; `stateStream()` returns an `AsyncStream<ModelInstallState>` that replays current state on subscribe; `_forceState(_ state:)` bypasses real download for test harness use; import `BackgroundAssets`, `Foundation`

### Persistence

- [x] T023 [P] [US1] Create `TranslatorApp/Data/Models/SessionQualityRecord.swift` — `@Model final class SessionQualityRecord` per data-model.md §2.1; fields: `id: UUID` (`@Attribute(.unique)`), `startedAt: Date`, `endedAt: Date?`, `engineId: String`, `accentGroupHint: String?`, `medianTokenConfidence: Double`, `p10TokenConfidence: Double`, `revisionRatePerMinute: Double`, `avgWordsPerSecond: Double`, `fragmentationScore: Double`, `latencyP50Ms: Double`, `latencyP95Ms: Double`, `hallucinatedEntityCount: Int`, `correctorInvocations: Int`, `correctorAcceptedCorrections: Int`, `conversationId: UUID?`; `nonisolated init(...)` sets `id = UUID()`, `startedAt = Date()`; **no transcript text fields**; import `SwiftData`; add `SessionQualityRecord` to the existing `ModelContainer` schema in `DependencyContainer`

### Domain Services (Modified)

- [x] T024 [US1] Modify `TranslatorApp/Domain/Services/QualityMetricsService.swift` — add `func recordTokenConfidences(_ tokens: [TranscriptToken]) async` that feeds into a running histogram; update histogram to track `p10: Float` (10th percentile) and `median: Float`; expose `var currentConfidenceP10: Float { get async }` so `NLPSegmenterService` and `DependencyContainer` can read it; keep all existing public API unchanged
- [x] T025 [US1] Modify `TranslatorApp/Domain/Services/NLPSegmenterService.swift` — add `private var pendingHypothesis: SpeechSegment?` stored property; in `processSegment()` (or equivalent): if `segment.isHypothesis == true`, store as `pendingHypothesis` and return without committing to the 3-tier cascade; when a `isFinal == true` segment arrives, clear `pendingHypothesis` and process the final segment normally through the cascade; hypothesis display (EN pane live tail) is driven by the ViewModel directly from the raw stream, not through this service

### Repository & Use Case (Modified)

- [x] T026 [US1] Modify `TranslatorApp/Data/Respository/SpeechRepository.swift` — add `init(engine: any SpeechEngineProtocol, qualityMetrics: QualityMetricsService)` alongside (or replacing) the existing init; in `startTranscription() async throws -> AsyncStream<SpeechSegment>`, delegate to `engine.start(options: SpeechEngineOptions())` then pipe result through `VADGate.filter()`; after each `isFinal` segment, call `await qualityMetrics.recordTokenConfidences(segment.tokens)`; `stopTranscription()` calls `engine.stop()`
- [x] T027 [US1] Modify `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift` — insert corrector pass in `executeBoth()`: after the pump Task reads a segment from the raw engine stream and before forwarding to the segmenter continuation, call `await correctorService.process(segment, deviceSupportsA17Pro: deviceCapabilities.supportsA17Pro)`; add loop-detection guard — if the last 5 final segments contain a 3-gram that appears ≥3 times, drop the segment and log a warning under category `UseCase`; keep existing fan-out pump Task structure and `stop()` cancellation unchanged

### Dependency Wiring

- [x] T028 [US1] Modify `TranslatorApp/App/DependencyContainer.swift` — add stored properties: `let downloadCoordinator: BackgroundAssetsCoordinator`, `let correctorService: TranscriptCorrectorService`, `let speechEngine: any SpeechEngineProtocol`; engine selection in `init()` follows data-model.md §4.1: if `EnginePreference.fromUserDefaults() == .appleOnly` → use `AppleSpeechAnalyzerEngine`; else if `downloadCoordinator.currentState == .installed && DeviceCapabilities.supportsA17Pro` → use `WhisperKitEngine`; else → use `AppleSpeechAnalyzerEngine` (or `LegacySFSpeechEngine` on iOS < 26); inject `speechEngine` into `SpeechRepository`; inject `correctorService` into `TranscribeAudioUseCase`; add `SessionQualityRecord` to `ModelContainer` schema; add pruning: after insert, if `SessionQualityRecord` count > 50 delete oldest by `startedAt`; expose `downloadCoordinator.stateStream()` to `TranscriptionViewModel`

**Checkpoint**: Build and run on A17 Pro+ device. Tap record. Speak L2 English — EN caption appears. ES caption appears within ~3 s. Logs show `engineId=whisperKitTurbo`. On a pre-A17 device, logs show `engineId=appleSpeechAnalyzer`. No crashes.

---

## Phase 4: User Story 2 — User Sees and Trusts the Quality Signal (Priority: P2)

**Goal**: Per-token confidence is visible as tonal opacity in the EN pane in real time. The corresponding ES segment inherits source min-confidence and renders at reduced opacity when the source was uncertain. Download consent sheet, progress bar, and Lite/Pro mode chip are present in the UI.

**Independent Test**: Feed a sentence where some words are clearly spoken and others mumbled. Verify the EN pane renders some tokens visibly brighter than others (not uniform). Verify the ES pane dims the whole segment when source confidence is low. Tap Settings — see engine picker.

- [x] T029 [US2] Modify `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` — add `@Published var modelInstallState: ModelInstallState = .notRequested`; add `@Published var enginePreference: EnginePreference = EnginePreference.fromUserDefaults()`; in `init()` start a `Task` that iterates `dependencyContainer.downloadCoordinator.stateStream()` and assigns each value to `modelInstallState` on `@MainActor`; add `func acceptModelDownload() async` and `func declineModelDownload() async` forwarding to `downloadCoordinator`; add `func saveEnginePreference(_ pref: EnginePreference)` that calls `pref.saveToUserDefaults()` and updates `enginePreference`
- [x] T030 [US2] Modify `TranslatorApp/Presentation/Views/LiveTranscriptionPanes.swift` — replace the flat `Text(segment.text)` EN caption with a `Group` that emits a `Text(token.text)` run for each token in `segment.tokens`, each with `.opacity(min(1.0, max(0.35, 0.35 + 0.65 * Double(token.confidence))))` and `.fontWeight(token.confidence >= 0.85 ? .semibold : .regular)`; when `segment.tokens.isEmpty` (legacy engine), fall back to single `Text(segment.text).opacity(Double(segment.confidence))`; apply the same pattern to the ES pane but as a single `Text` using `minSourceConfidence` from the translation entry (see T045)
- [x] T031 [US2] Modify `TranslatorApp/Presentation/Views/LiveTranscriptionView.swift` — add `.sheet(isPresented: ...)` triggered when `viewModel.modelInstallState == .awaitingConsent` that presents a consent card with "Download enhanced accuracy model (~600 MB, Wi-Fi recommended)" text and Accept/Decline buttons calling `viewModel.acceptModelDownload()`/`viewModel.declineModelDownload()`; add a `ProgressView` in the EN pane header during `.downloading(progress:)` showing the progress value; add a "Lite" mode chip (small capsule label) below the record button when `modelInstallState != .installed`; add a `NavigationLink` to `EnginePreferenceView`
- [x] T032 [P] [US2] Create `TranslatorApp/Presentation/Views/Settings/EnginePreferenceView.swift` — `struct EnginePreferenceView: View` with `@ObservedObject var viewModel: TranscriptionViewModel`; `Form` containing: (1) `Picker("Engine", selection: $viewModel.enginePreference)` with `.auto`/`.appleOnly`/`.whisperPreferred` options, onChange calls `viewModel.saveEnginePreference()`; (2) `LabeledContent("Model status", ...)` showing current `modelInstallState` as human-readable text; (3) `Button("Re-download model")` visible only when `modelInstallState == .failed || modelInstallState == .declined`, calls `viewModel.acceptModelDownload()`; follows existing SwiftUI style in the codebase

**Checkpoint**: Build and run. Navigate to settings — see engine picker. Return to main view. Record L2 speech — tokens appear with visible opacity variation in the EN pane. ES segment dims when source confidence is low. First-run consent sheet appears on a fresh install.

---

## Phase 5: User Story 3 — Diagnostic Baseline & Regression Protection (Priority: P2)

**Goal**: A reproducible offline evaluation harness replays a labeled audio corpus through the live pipeline and emits a numeric JSON report covering SC-001..SC-010. A second run on the same build reproduces headline metrics within ±0.5 pp.

**Independent Test**: Run `xcodebuild test -only-testing:TranslatorAppEvaluationTests/EdAccSubsetEvaluation` with a 5-item mini-corpus; verify JSON report is emitted with all required fields. CLI tool `evaluation-delta` compiles and prints a verdict.

### Harness Data Types

- [x] T033 [P] [US3] Create `TranslatorAppEvaluationTests/Evaluation/EvaluationCorpusManifest.swift` — `struct EvaluationCorpusManifest: Codable, Sendable` with `name: String`, `license: String`, `items: [Item]`; nested `struct Item: Codable, Sendable` with `id`, `audioPath`, `referenceTranscript`, `accentGroup: AccentGroup`, `speakerId`, `durationSeconds: Double`; add to `TranslatorAppEvaluationTests` target; import `Foundation` only
- [x] T034 [P] [US3] Create `TranslatorAppEvaluationTests/Evaluation/EvaluationReport.swift` — `struct EvaluationReport: Codable, Sendable` per data-model.md §3.2; use `[String: Double]` for `wer` and `cer` keyed by `AccentGroup.rawValue`; nested structs `Totals`, `Intelligibility`, `Latency`, `ConfidenceCalibration`, `HallucinationCounter`, `CorrectorStats` all `Codable, Sendable`; add to evaluation target
- [x] T035 [P] [US3] Create `TranslatorAppEvaluationTests/Evaluation/EvaluationDelta.swift` — `struct EvaluationDelta: Codable, Sendable` with `baseline`, `candidate`, `verdict: Verdict`, `werDelta: [String: WERPoint]`, `gates: [Gate]`; `enum Verdict: String, Codable, Sendable` with six cases from contracts; nested `WERPoint` and `Gate` structs per data-model.md §3.3; add to evaluation target

### Harness Utilities

- [x] T036 [P] [US3] Create `TranslatorAppEvaluationTests/Evaluation/WERCalculator.swift` — `struct WERCalculator` (value type, Sendable); `func wer(hypothesis: String, reference: String) -> Double` — lowercase both, strip punctuation, split on whitespace, compute Levenshtein edit distance (insertions + deletions + substitutions), divide by reference word count; `func cer(hypothesis: String, reference: String) -> Double` — same at character level; add to evaluation target; import `Foundation` only
- [x] T037 [P] [US3] Create `TranslatorAppEvaluationTests/Evaluation/EntityExtractor.swift` — `struct EntityExtractor` (value type, Sendable); `func entities(in text: String) -> Set<String>` — wraps `NLTagger` with `.nameType` scheme, returns lowercased set of all person/place/organization tokens; `func numerals(in text: String) -> Set<String>` — regex `\b\d+([.,]\d+)?\b` + spelled-out number words (one, two … twenty); used by harness and corrector to validate anti-hallucination invariant; import `NaturalLanguage`, `Foundation`

### Harness Protocol & Implementation

- [x] T038 [US3] Create `TranslatorAppEvaluationTests/Evaluation/EvaluationHarnessProtocol.swift` — copy from `specs/005-accent-robust-asr/contracts/EvaluationHarnessProtocol.swift`; types now resolve because T033–T037 are in scope; add to evaluation target; import `Foundation` only
- [x] T039 [US3] Create `TranslatorAppEvaluationTests/Evaluation/EvaluationHarness.swift` — `actor EvaluationHarness: EvaluationHarnessProtocol`; `func run(manifest:engine:corrector:buildId:)`: for each corpus item: (1) load audio from `item.audioPath` relative to manifest file URL as `AVAudioFile`, (2) feed audio to `engine.start()` at real-time pace using `AVAudioPlayerNode` into the engine's input, (3) collect final segments, (4) compute WER via `WERCalculator`, (5) measure wall-clock latency from audio segment start to `isFinal == true` receipt, (6) run `EntityExtractor` on EN text + translated text pair, (7) aggregate into `EvaluationReport`; `compare(baseline:candidate:)` computes deltas and applies SC gates; stay under 240 lines — split into `EvaluationHarness+Run.swift` if needed; import `AVFoundation`, `Foundation`

### Corpus README

- [x] T040 [P] [US3] Create `TranslatorAppEvaluationTests/Corpora/README.md` — instructions to fetch: (a) EdAcc dev set from `https://huggingface.co/datasets/edinburghcstr/edacc` (CC-BY-SA-4.0, ~400 utterances), (b) L2-ARCTIC from CMU (CC-BY-4.0), (c) LibriSpeech test-clean from `https://openslr.org/12/` (CC-BY-4.0); specify expected directory layout relative to `Corpora/`; provide a sample 5-item `manifest.json` the developer can create manually to smoke-test without the full download

### Harness Test Cases

- [x] T041 [US3] Create `TranslatorAppEvaluationTests/Tests/EdAccSubsetEvaluation.swift` — `class EdAccSubsetEvaluation: XCTestCase`; `func testAccentWER()` loads `edacc-subset-v1/manifest.json` from an environment variable path (skip with `XCTSkip("corpus not present")` if absent); runs harness; asserts `report.wer["italian"]! < baselineWER["italian"]! * 0.70` (SC-001 ≥30% relative reduction), `report.wer["native"]! <= baselineWER["native"]! + 0.02` (SC-002), `report.hallucinatedEntities.count == 0` (SC-004), `report.confidenceCalibration.spearmanRho >= 0.6` (SC-005), `report.latency.p95Ms <= 4000.0` (SC-006); writes report JSON to `evaluation-reports/005-accent-robust-asr@\(buildId).json`
- [x] T042 [P] [US3] Create `TranslatorAppEvaluationTests/Tests/ReproducibilityTest.swift` — `class ReproducibilityTest: XCTestCase`; `func testSC009()` calls `harness.verifyReproducibility(manifest:engine:corrector:epsilon:0.005)` using a 10-item mini-manifest; asserts return value is `true` (both runs agree within ±0.5 pp on headline WER)
- [x] T043 [P] [US3] Create `TranslatorAppEvaluationTests/Tests/LibriSpeechRegressionEvaluation.swift` — `class LibriSpeechRegressionEvaluation: XCTestCase`; `func testNativeRegressionSC002()` runs LibriSpeech test-clean subset; asserts `candidateWER["native"]! - baselineWER["native"]! <= 0.02`; skip with `XCTSkip` when corpus absent

### evaluation-delta CLI Tool

- [x] T044 [US3] Create `TranslatorAppEvaluationTests/Tools/evaluation-delta/main.swift` — Swift CLI; parse args `--baseline <path>`, `--candidate <path>`, `--output <path>` using `CommandLine.arguments`; `JSONDecoder().decode(EvaluationReport.self, from: Data(contentsOf: ...))` for both inputs; instantiate `EvaluationHarness()` and call `compare(baseline:candidate:)`; encode delta with `JSONEncoder()` and write to output path; `exit(delta.verdict == .accepted ? 0 : 1)`; add as Swift executable target in `TranslatorApp.xcodeproj`

**Checkpoint**: `xcodebuild test -only-testing:TranslatorAppEvaluationTests/EdAccSubsetEvaluation` runs (even if corpus absent — produces XCTSkip). `xcodebuild build -target evaluation-delta` compiles. With a mini-corpus present, JSON report is written with all expected fields.

---

## Phase 6: User Story 4 — Graceful Degradation on Bad Source (Priority: P3)

**Goal**: When the English transcript is garbled, the Spanish pane does not emit confident-sounding nonsense. Loop/repetition detection prevents amplified ASR failure. Empty or silence-only segments produce no ES output. Named entities are never hallucinated.

**Independent Test**: Run `CorrectorAntiHallucination` test suite — all 50 hand-crafted broken segments produce output with no new entity. Play a looped/repeated audio clip — the ES pane does not loop correspondingly.

- [x] T045 [US4] Modify `TranslatorApp/Presentation/ViewModels/TranscriptionViewModel.swift` — introduce `struct TranslationEntry: Sendable { let text: String; let minSourceConfidence: Float }`; change `translatedSentences: [String]` to `translatedSentences: [TranslationEntry]`; update `appendTranslation(_ text: String, sourceConfidence: Float)` (new param); update dedup logic to compare `.text` field; update `saveConversation()` to use `entry.text`; update all callers in the ViewModel
- [x] T046 [US4] Modify `TranslatorApp/Presentation/Views/LiveTranscriptionPanes.swift` — update the ES pane to iterate `viewModel.translatedSentences: [TranslationEntry]`; apply per-entry opacity: `opacity = min(1.0, max(0.35, 0.35 + 0.65 * Double(entry.minSourceConfidence)))`; single `Text(entry.text)` per entry (no token-by-token on ES side)
- [x] T047 [US4] Modify `TranslatorApp/Domain/UseCases/TranscribeAudioUseCase.swift` — add `private var recentFinalSegments: [SpeechSegment] = []` (bounded to last 5); after each corrected final segment: (1) append to `recentFinalSegments`, trim to 5; (2) extract all 3-word n-grams from the segment text; (3) count how many times each n-gram appears across the 5 recent segments; (4) if any 3-gram appears ≥3 times, drop the segment (do not forward to segmenter or translation), log a `warning` under category `UseCase` with message `"[LOOP-DETECT] dropped segment: \(segment.text)"`; this guards SC-006 / SC-008 against WhisperKit silence-loop hallucinations
- [x] T048 [P] [US4] Create `TranslatorAppEvaluationTests/Tests/CorrectorAntiHallucination.swift` — `class CorrectorAntiHallucination: XCTestCase`; load static fixture `Tests/Fixtures/broken-transcripts.json` (50 `SpeechSegment`-like dicts with `text`, `tokens`, `confidence` per token); for each, call `FoundationModelsCorrector.correct(segment:lockThreshold:0.85)`; assert: (a) `EntityExtractor.entities(in: output)` is a subset of `EntityExtractor.entities(in: input)`, (b) `EntityExtractor.numerals(in: output)` is a subset of `EntityExtractor.numerals(in: input)`, (c) all tokens with `isLocked == true` appear byte-identical in output; create the fixture file `TranslatorAppEvaluationTests/Tests/Fixtures/broken-transcripts.json` with 50 hand-crafted entries covering truncated, repeated, and low-confidence cases

**Checkpoint**: `xcodebuild test -only-testing:TranslatorAppEvaluationTests/CorrectorAntiHallucination` passes all 50 cases. Play a looped audio clip — no looped ES output. Empty spoken segment → no ES output emitted.

---

## Final Phase: Polish & Cross-Cutting Concerns

**Purpose**: OSLog for all new components, SC-010 failure injection paths, record pruning, short-utterance guard. Can begin once Phase 3 is complete; independent of Phases 4–6.

- [x] T049 [P] Add `OSLog` structured logging to all new actor files — `AppleSpeechAnalyzerEngine.swift`, `WhisperKitEngine.swift`, `FoundationModelsCorrector.swift`, `BackgroundAssetsCoordinator.swift`, `TranscriptCorrectorService.swift`; each uses `Logger(subsystem: "com.spanesso.TraslatorApp", category: "<FileName>")` and logs at `info` level on session start/stop, `debug` level per-segment with `engineId=`, `confidence=`, `correctorResult=`
- [x] T050 [P] Implement SC-010 failure injection paths in `TranslatorApp/App/DependencyContainer.swift` — (1) observe `AVAudioSession.interruptionNotification` and `AVAudioSession.mediaServicesWereLostNotification`; on interrupt, set `transcriptionViewModel.translatorState = .permissionDenied` within 3 s and call `speechEngine.stop()`; (2) at session start, if `downloadCoordinator.currentState == .installed` but model files are absent from disk (check `FileManager.default.fileExists`), set state to `.notRequested` and log an `error`; (3) download coordinator already emits `.failed(.networkUnavailable)` — ensure `DependencyContainer` forwards this to `transcriptionViewModel.modelInstallState` via the `stateStream()` subscription wired in T028
- [x] T051 [P] Add short-utterance guard to `TranslatorApp/Domain/Services/NLPSegmenterService.swift` — before forwarding any segment to the translation continuation, check `segment.text.split(separator: " ").count < 2`; if true, log at `debug` level under category `Segmenter` (`"[SHORT-UTTERANCE suppressed] \(segment.text)"`) and return without emitting; this prevents single-word fragments from producing spurious ES translations
- [x] T052 [P] Verify `SessionQualityRecord` pruning in `TranslatorApp/App/DependencyContainer.swift` — after each `modelContext.insert(record)`, fetch count of `SessionQualityRecord` using `FetchDescriptor<SessionQualityRecord>(sortBy: [SortDescriptor(\.startedAt)])`; if count > 50, delete the first (oldest) entry via `modelContext.delete(_:)`; `modelContext.save()` or rely on autosave; add a unit test in `TranslatorAppTests` that inserts 51 records and asserts count remains ≤ 50

---

## Dependency Graph

```
Phase 1 (Setup)
    └─→ Phase 2 (Foundational entities + protocols)
             └─→ Phase 3 (US1 — Engine stack, MVP)
                      ├─→ Phase 4 (US2 — Confidence UI)
                      ├─→ Phase 5 (US3 — Harness)
                      ├─→ Phase 6 (US4 — Graceful degradation)
                      └─→ Final Phase (Polish — overlaps with 4, 5, 6)
```

Phases 4, 5, 6, and Final are **independent of each other** and can be implemented in parallel by separate engineers once Phase 3 lands on the branch.

---

## Parallel Execution Examples

**Within Phase 2** (all touch different files):
```
T005 TranscriptToken.swift
T006 EngineId.swift             ← parallel
T007 AccentGroup.swift          ← parallel
T008 EnginePreference.swift     ← parallel
T009 ModelInstallState.swift    ← parallel
T011 TranslatorState.swift      ← parallel
T012 SpeechError.swift          ← parallel
T014 TranscriptCorrectorProtocol.swift  ← parallel
T015 ModelDownloadCoordinatorProtocol.swift  ← parallel
```

**Within Phase 3** (engine adapters touch different files):
```
T016 LegacySFSpeechEngine.swift     ← parallel with T017, T021, T023
T017 VADGate.swift                  ← parallel
T021 TranscriptCorrectorService.swift  ← parallel
T023 SessionQualityRecord.swift     ← parallel
```
(T018 AppleSpeechAnalyzerEngine and T019 WhisperKitEngine both use VADGate, so start after T017)

**Within Phase 5** (harness data types are all independent):
```
T033 EvaluationCorpusManifest.swift  ← parallel with T034, T035, T036, T037, T040
T034 EvaluationReport.swift          ← parallel
T035 EvaluationDelta.swift           ← parallel
T036 WERCalculator.swift             ← parallel
T037 EntityExtractor.swift           ← parallel
T040 Corpora/README.md               ← parallel
```

---

## Implementation Strategy

### MVP (Phases 1–3 only — US1 delivered)

Scope: WhisperKit integrated, tiered engine selection, corrector, download coordinator, DependencyContainer wired. L2 speakers are transcribed more accurately. No quality UI, no harness.

Verification: manual test with a held-out L2 recording on A17 Pro+ device.

### Increment 2 — Phase 4 (US2: visible confidence)

Tonal opacity + download consent + mode chip. Can be developed in parallel with Increment 3.

### Increment 3 — Phase 5 (US3: harness)

Numeric evidence that SC-001 is actually met. Required before any marketing claim. Can be developed in parallel with Increment 2.

### Increment 4 — Phase 6 (US4: graceful degradation)

Loop detection + confidence inheritance on ES side + anti-hallucination tests. Completes the P3 story.

### Final — Polish

OSLog, failure injection, pruning, short-utterance guard. Low risk; apply at the end or interleaved.

---

## Summary

| Phase | Tasks | User Story | Parallel-eligible tasks |
|---|---|---|---|
| Phase 1 — Setup | T001–T004 | — | T002, T003, T004 |
| Phase 2 — Foundational | T005–T015 | — | T006–T009, T011–T012, T014–T015 |
| Phase 3 — US1 (P1, MVP) | T016–T028 | US1 | T016, T017, T021, T023 |
| Phase 4 — US2 (P2) | T029–T032 | US2 | T032 |
| Phase 5 — US3 (P2) | T033–T044 | US3 | T033–T037, T040, T042, T043 |
| Phase 6 — US4 (P3) | T045–T048 | US4 | T048 |
| Final — Polish | T049–T052 | — | T049, T050, T051, T052 |
| **Total** | **52 tasks** | | |
