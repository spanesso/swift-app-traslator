# Implementation Plan: Accent-Robust English ASR & Intelligible Translation

**Branch**: `005-accent-robust-asr` | **Date**: 2026-06-17 | **Spec**: [./spec.md](./spec.md)
**Input**: Feature specification from `/specs/005-accent-robust-asr/spec.md`

## Summary

Replace the single-engine `SFSpeechRecognizer` pipeline with a **tiered hybrid ASR + post-correction pipeline** for iOS 26, targeting non-native English speakers. The headline change is that the engine layer becomes pluggable: iOS 26 `SpeechAnalyzer` is the always-available baseline, **WhisperKit large-v3-turbo (compressed, ~0.6 GB, one-time consented download)** is the accent-robust default on A17 Pro+ devices, and **Apple Foundation Models** (3 B on-device LLM) provides a confidence-gated, span-locked post-correction stage that is forbidden by construction from introducing hallucinated entities or numerals. Per-token confidence flows end-to-end and drives a tonal-opacity UI. A new evaluation-harness test target replays a labeled corpus (EdAcc + L2-ARCTIC + LibriSpeech) through the live pipeline and emits a numeric report that gates every build against SC-001…SC-010.

## Technical Context

**Language/Version**: Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency)
**Primary Dependencies (new)**:
- `WhisperKit` (Swift Package, MIT — `argmaxinc/argmax-oss-swift`) — Tier 1 engine
- Apple `Speech` framework — iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` (system) — Tier 0 engine
- Apple `FoundationModels` framework (system, A17 Pro+) — Tier 2 corrector
- Apple `BackgroundAssets` framework (system) — model download coordinator
- Apple `Translation` framework (system, on-device) — output stage (unchanged)
- `NaturalLanguage` (system) — segmenter input (unchanged), token-text utilities

**Primary Dependencies (retained)**: SwiftUI, AVFoundation, OSLog, SwiftData. No new third-party packages beyond WhisperKit. **WhisperKit is the only new external dependency** — its inclusion is justified in *Constitution Check* below.

**Storage**:
- SwiftData (existing) — `ConversationRecord` (unchanged) and **new** `SessionQualityRecord`
- Disk — WhisperKit model files in App Support, managed by `BackgroundAssets`
- No new file types outside the sandbox

**Testing**: XCTest. **New** `TranslatorAppEvaluationTests` target that drives the live pipeline against a developer-side corpus directory (not bundled in app). Existing `TranslatorAppUITests` and `TranslatorAppTests` are preserved.

**Target Platform**: iOS 26+ on iPhone (CL-2). iPad as best-effort. macOS is no longer the shipping target for this feature (the existing macOS build is kept as a developer workstation).

**Project Type**: Mobile app (single-target iOS app).

**Performance Goals**: see SC-006 in `spec.md` — median end-to-end ≤ 2.5 s, p95 ≤ 4.0 s on iPhone 15 Pro reference.

**Constraints**:
- 100 % offline at runtime. Only a one-time consented model download is allowed.
- A17 Pro+ feature gate for Tier 1 and Tier 2; older devices stay on Tier 0.
- WhisperKit compressed model ≈ 0.6 GB on disk; combined peak RAM < 2 GB.
- App must remain functional during/after install before the heavy model arrives.

**Scale/Scope**: 1 active session at a time, < 30 ongoing translation segments in memory, < 50 `SessionQualityRecord` rows retained.

## Constitution Check

There is no project-specific constitution file (`.specify/memory/constitution.md` is the template). The **de-facto constitution** for this codebase is `CLAUDE.md`'s *Non-Negotiable Rules* and the inner `swift-app-traslator/CLAUDE.md` Key Design Decisions. The plan is gated against those.

### Gate 1 — Clean Architecture boundaries

> **Rule** (CLAUDE.md): `Presentation → Domain ← Data`. Domain imports only `Foundation`, `CoreGraphics`, `simd`, `CoreMedia`. No AVFoundation, UIKit, SwiftUI, OpenCV in Domain.

- **Plan compliance**: All four new Domain protocols (`SpeechEngineProtocol`, `TranscriptCorrectorProtocol`, `ModelDownloadCoordinatorProtocol`, `EvaluationHarnessProtocol`) import only `Foundation`. Concrete adapters (`AppleSpeechAnalyzerEngine`, `WhisperKitEngine`, `FoundationModelsCorrector`, `BackgroundAssetsCoordinator`) live in `Data/` and import the framework-specific symbols.
- **Status**: ✅ PASS.

### Gate 2 — No `@StateObject` for ViewModels inside Views

> **Rule**: ViewModels owned only by the App composition root.

- **Plan compliance**: `DependencyContainer` continues to own all long-lived instances. No new `@StateObject` in any View. The new pieces (`ModelDownloadCoordinator`, `TranscriptCorrector`) are owned by `DependencyContainer` and passed in via init.
- **Status**: ✅ PASS.

### Gate 3 — Threading

> **Rule**: Capture + detection outside MainActor; UI on MainActor; never cross. Anything > 5 ms goes to a background queue.

- **Plan compliance**:
  - Engines remain actor-isolated (`AppleSpeechAnalyzerEngine` is an actor, `WhisperKitEngine` is an actor).
  - The corrector is an actor; Foundation Models calls happen off the MainActor.
  - The evaluation harness runs on a dedicated test queue.
  - `TranscriptionViewModel` (MainActor) only reads finalized segments and updates `@Observable` properties.
- **Status**: ✅ PASS.

### Gate 4 — Swift 6 strict concurrency, no `@unchecked Sendable`

> **Rule**: Build without concurrency warnings.

- **Plan compliance**: All new types are `Sendable` by construction (enums, structs of `Sendable` fields, actors). `SpeechSegment`'s new `tokens: [TranscriptToken]` field is `Sendable`. No `@unchecked` introduced.
- **Status**: ✅ PASS.

### Gate 5 — No new dependencies without justification

> **Rule**: "No adding dependencies. No package managers."

- **Violation**: WhisperKit (Swift Package, MIT) is a new external dependency.
- **Justification**: Documented in *Complexity Tracking* below. Without WhisperKit, SC-001 (≥30 % relative WER reduction on L2 English) is not credibly reachable. The alternatives are (a) Apple `SpeechAnalyzer` alone — measured to be insufficient on accented English vs Whisper, (b) `whisper.cpp` manual XCFramework — strictly worse iOS integration with no ANE advantage, (c) reimplement Whisper in Swift — multi-year effort. The MIT license, the absence of any runtime network call, and the App-Store-blessed Background Assets delivery pattern make this the lowest-friction high-value dependency we can add.
- **Status**: ⚠️ JUSTIFIED VIOLATION. See *Complexity Tracking*.

### Gate 6 — Domain entities pure Swift

> **Rule**: Domain layer pure.

- **Plan compliance**: New entities (`TranscriptToken`, `EngineId`, `AccentGroup`, `EnginePreference`, `ModelInstallState`) use only `Foundation`. The extended `SpeechSegment` adds two optional fields that remain `Sendable` and Foundation-only.
- **Status**: ✅ PASS.

### Gate 7 — Honesty over silence

> **Rule** (spec FR-012, SC-010): No silent failure.

- **Plan compliance**: Every failure path (model missing, network lost, permission revoked, device unsupported) surfaces an explicit `TranslatorState` change within 3 s. The quickstart enumerates the failure-injection tests.
- **Status**: ✅ PASS.

### Constitution Check verdict
**PASS with one justified violation** (Gate 5 — WhisperKit dependency). Proceed to design phases.

## Project Structure

### Documentation (this feature)

```text
specs/005-accent-robust-asr/
├── spec.md                  # User-facing contract (already written)
├── plan.md                  # This file
├── research.md              # FASE 2 + FASE 3 analysis (already written)
├── data-model.md            # Entities + persistence + harness JSON (already written)
├── quickstart.md            # "Did the feature work?" verification (already written)
├── contracts/               # Swift protocol files (spec artifacts, not compile units)
│   ├── README.md
│   ├── SpeechEngineProtocol.swift
│   ├── TranscriptCorrectorProtocol.swift
│   ├── ModelDownloadCoordinatorProtocol.swift
│   └── EvaluationHarnessProtocol.swift
├── checklists/
│   └── requirements.md      # Spec quality checklist
└── tasks.md                 # NOT created by /speckit-plan — produced by /speckit-tasks
```

### Source code (repository root)

```text
TranslatorApp/
├── App/
│   ├── TranslatorAppApp.swift                       # unchanged
│   └── DependencyContainer.swift                    # MODIFY — wire new engines, corrector, download coordinator
├── Domain/
│   ├── Entities/
│   │   ├── SpeechSegment.swift                      # MODIFY — add optional tokens / source / isHypothesis
│   │   ├── TranscriptToken.swift                    # NEW
│   │   ├── EngineId.swift                           # NEW
│   │   ├── AccentGroup.swift                        # NEW
│   │   ├── EnginePreference.swift                   # NEW
│   │   ├── ModelInstallState.swift                  # NEW
│   │   ├── TranslatorState.swift                    # MODIFY — add downloadingASRModel, correcting
│   │   ├── QualitySnapshot.swift                    # unchanged
│   │   ├── SpeechError.swift                        # MODIFY — add modelUnavailable, deviceUnsupported, downloadFailed
│   │   └── ConversationEntity.swift                 # unchanged
│   ├── Interfaces/
│   │   ├── SpeechRepositoryProtocol.swift           # unchanged (use-case-facing surface preserved)
│   │   ├── SpeechEngineProtocol.swift               # NEW (from contracts/)
│   │   ├── TranscriptCorrectorProtocol.swift        # NEW (from contracts/)
│   │   ├── ModelDownloadCoordinatorProtocol.swift   # NEW (from contracts/)
│   │   ├── NLPSegmenterServiceProtocol.swift        # unchanged
│   │   └── ConversationRepositoryProtocol.swift     # unchanged
│   ├── Services/
│   │   ├── NLPSegmenterService.swift                # MODIFY — handle hypothesis vs confirmed split
│   │   ├── QualityMetricsService.swift              # MODIFY — record per-token confidence histogram
│   │   ├── TranscriptCorrectorService.swift         # NEW — wraps FoundationModelsCorrector behind protocol
│   │   └── TranslationContextWindow.swift           # unchanged
│   └── UseCases/
│       ├── TranscribeAudioUseCase.swift             # MODIFY — fan-out now includes corrector pass
│       ├── SaveConversationUseCase.swift            # unchanged
│       └── FetchConversationsUseCase.swift          # unchanged
├── Data/
│   ├── ContinuousSpeechListener.swift               # KEEP — becomes legacy SFSpeechRecognizer adapter
│   ├── SpeechEngines/                               # NEW directory
│   │   ├── AppleSpeechAnalyzerEngine.swift          # NEW — iOS 26 SpeechAnalyzer adapter (Tier 0)
│   │   ├── WhisperKitEngine.swift                   # NEW — WhisperKit adapter (Tier 1)
│   │   └── LegacySFSpeechEngine.swift               # NEW — thin adapter over existing ContinuousSpeechListener
│   ├── Audio/
│   │   └── VADGate.swift                            # NEW — voice-activity gate upstream of engines
│   ├── Correctors/
│   │   └── FoundationModelsCorrector.swift          # NEW — span-locked corrector
│   ├── Coordinators/
│   │   └── BackgroundAssetsCoordinator.swift        # NEW — wraps BackgroundAssets framework
│   ├── Models/
│   │   ├── ConversationRecord.swift                 # unchanged
│   │   └── SessionQualityRecord.swift               # NEW SwiftData @Model
│   ├── Repositories/
│   │   └── ConversationRepository.swift             # unchanged
│   └── Respository/                                 # (existing typo preserved)
│       └── SpeechRepository.swift                   # MODIFY — accepts SpeechEngineProtocol injected
└── Presentation/
    ├── ViewModels/
    │   ├── TranscriptionViewModel.swift             # MODIFY — surface ModelInstallState, EnginePreference
    │   └── ConversationHistoryViewModel.swift       # unchanged
    └── Views/
        ├── LiveTranscriptionView.swift              # MODIFY — host download progress + Lite/Pro indicator
        ├── LiveTranscriptionPanes.swift             # MODIFY — render per-token opacity
        ├── RecordButton.swift                       # unchanged
        ├── ConversationDetailView.swift             # unchanged
        ├── ConversationExport.swift                 # unchanged
        ├── ConversationHistoryView.swift            # unchanged
        └── Settings/
            └── EnginePreferenceView.swift           # NEW — Lite vs Pro toggle, manual re-download

TranslatorAppTests/                                  # existing target, mostly unchanged
TranslatorAppUITests/                                # existing target, mostly unchanged

TranslatorAppEvaluationTests/                        # NEW test target — NOT bundled with shipping app
├── Evaluation/
│   ├── EvaluationHarness.swift                     # NEW — implements EvaluationHarnessProtocol
│   ├── EvaluationHarnessProtocol.swift             # NEW (from contracts/)
│   ├── EvaluationCorpusManifest.swift              # NEW
│   ├── EvaluationReport.swift                      # NEW
│   ├── EvaluationDelta.swift                       # NEW
│   ├── WERCalculator.swift                         # NEW — Levenshtein-based WER/CER
│   └── EntityExtractor.swift                       # NEW — NLTagger-based proper-noun/numeral set
├── Corpora/
│   └── README.md                                   # NEW — instructions to fetch EdAcc, L2-ARCTIC, etc.
├── Tests/
│   ├── EdAccSubsetEvaluation.swift                 # NEW — runs the primary corpus
│   ├── L2ArcticEvaluation.swift                    # NEW
│   ├── LibriSpeechRegressionEvaluation.swift       # NEW — SC-002 native regression gate
│   ├── CorrectorAntiHallucination.swift            # NEW — SC-004 / SC-008 gate
│   └── ReproducibilityTest.swift                   # NEW — SC-009 gate
└── Tools/
    └── evaluation-delta/                            # NEW Swift executable target
        └── main.swift                              # produces EvaluationDelta JSON from two reports
```

**Structure Decision**: Single iOS app target (`TranslatorApp`) following the existing Clean Architecture layout, augmented with one new test target (`TranslatorAppEvaluationTests`) and one Swift executable target (`evaluation-delta`). The Domain/Data/Presentation layering is preserved as-is. New code is additive in dedicated subdirectories (`Data/SpeechEngines/`, `Data/Audio/`, `Data/Correctors/`, `Data/Coordinators/`). The single biggest modification to existing code is the `SpeechSegment` extension — done as additive optional fields so every existing caller continues to compile unchanged.

## Complexity Tracking

| Violation | Why Needed | Simpler Alternative Rejected Because |
|-----------|------------|--------------------------------------|
| **WhisperKit** added as a Swift Package dependency (violates "no adding dependencies" rule from CLAUDE.md) | SC-001 (≥30 % rel WER reduction on L2 English) is not credibly reachable on Apple's stack alone. WhisperKit is MIT, runs entirely on-device, scheduled across ANE/GPU/CPU, and exposes the hypothesis/confirmed dual stream that maps cleanly onto the existing `executeBoth()` fan-out. | (a) Apple `SpeechAnalyzer` alone — measured at 14.0 % WER on Earnings22 vs WhisperKit-small at 12.8 %; the gap widens on heavy L2 audio. (b) `whisper.cpp` via manual XCFramework — same model accuracy as WhisperKit but materially worse iOS integration (no ANE scheduler, no streaming-native hypothesis/confirmed split). (c) Implement Whisper in Swift from scratch — multi-year, not a feature-scoped engineering effort. (d) Cloud Whisper API — rejected during CL-1 (no runtime network). |
| New `TranslatorAppEvaluationTests` test target (new build product, slightly increases project complexity) | Without a reproducible evaluation harness, every claimed improvement is anecdotal. SC-001/SC-002/SC-009 are unfalsifiable without it. | Inline tests inside the existing `TranslatorAppTests` target — rejected because the evaluation corpora must NOT ship to the App Store (license + size); a dedicated test target with its own resources directory is the App-Review-clean way to separate them. |
| Tiered hybrid pipeline (two engines + a corrector) rather than picking one engine | SC-001 needs the heavy engine, SC-002 needs the always-available baseline (older devices), SC-008 needs the corrector for anti-hallucination. No single component satisfies all three. | (a) WhisperKit-only — fails SC-002 on pre-A17 devices (no fallback) and SC-010 during the model download window. (b) Apple-only — fails SC-001 on L2 accents. (c) Corrector-only — corrects nothing because there's no upstream lift. |

## Post-Design Constitution Re-check

After designing the structure above, re-evaluating each gate:

- **Gate 1 (Clean Architecture)**: All new protocol files import only Foundation. Concrete engines / coordinators / correctors are confined to `Data/`. ✅
- **Gate 2 (@StateObject)**: All new long-lived state owned by `DependencyContainer`. ✅
- **Gate 3 (Threading)**: All new heavy work (model inference, corrector) is actor-isolated off MainActor. ✅
- **Gate 4 (Strict concurrency)**: All new types `Sendable` by construction. ✅
- **Gate 5 (Dependencies)**: WhisperKit justified above. ⚠️ Justified.
- **Gate 6 (Domain purity)**: New entities Foundation-only. ✅
- **Gate 7 (No silent failure)**: Every failure path enumerated in `quickstart.md` step 5. ✅
- **Gate 8 (File length)**: CLAUDE.md says "Max 250 lines per Swift file." Largest new files projected: `WhisperKitEngine.swift` (~220 lines), `EvaluationHarness.swift` (~240 lines), `FoundationModelsCorrector.swift` (~200 lines). All under the cap; tasks.md will enforce splits if any approach the limit during implementation. ✅

**Post-design verdict**: PASS with the same single justified dependency violation. Ready for `/speckit-tasks`.
