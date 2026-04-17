# Implementation Plan: Improve Live Transcription & Translation Quality

**Branch**: `001-improve-transcription-translation` | **Date**: 2026-04-17 | **Spec**: [spec.md](./spec.md)  
**Input**: Feature specification from `specs/001-improve-transcription-translation/spec.md`

## Summary

Fix three compounding defects that cause fragmented, duplicated, and context-free translations in the live transcription app: (1) `pendingSuffix()` word-count diffing drifts under ASR corrections, emitting overlapping segments; (2) `currentBuffer` displays the full accumulated transcript, visually duplicating already-committed `emittedPhrases`; (3) Apple Translation receives isolated sentence fragments with no prior context, causing idiom failures. The technical approach modifies `NLPSegmenterService` (string-prefix diff), `TranscriptionViewModel` (uncommitted-tail display + full-array dedup), and `LiveTranscriptionView` (context injection into translation requests), plus a new lightweight `TranslationContextWindow` value type.

## Technical Context

**Language/Version**: Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`  
**Primary Dependencies**: SwiftUI, Speech (SFSpeechRecognizer), AVFoundation, NaturalLanguage (NLTokenizer), Translation (Apple on-device), OSLog  
**Storage**: In-memory only (no persistence required)  
**Testing**: XCTest (UI test scaffolding exists; manual test cases defined in quickstart.md)  
**Target Platform**: macOS (IPHONEOS_DEPLOYMENT_TARGET = 26.1 in pbxproj, but CLAUDE.md confirms macOS)  
**Project Type**: Desktop app (single Xcode project, no external packages)  
**Performance Goals**: Translation latency < 2s after sentence boundary; zero frame drops during continuous 30-min session  
**Constraints**: Fully offline (on-device only); no new external dependencies; strict actor isolation enforced by compiler  
**Scale/Scope**: Single-user, single session at a time; ~1,300 lines total across all source files

## Constitution Check

*GATE: Constitution is a placeholder template — no project-specific principles have been ratified. No gate violations to evaluate.*

Recommended: Run `/speckit-constitution` after this feature ships to capture the emerging patterns (actor-based concurrency, differential emit, clean architecture layering) as formal principles.

## Project Structure

### Documentation (this feature)

```text
specs/001-improve-transcription-translation/
├── plan.md              ← this file
├── research.md          ← Phase 0 output
├── data-model.md        ← Phase 1 output
├── quickstart.md        ← Phase 1 output
├── contracts/
│   └── async-stream-contracts.md   ← Phase 1 output
├── checklists/
│   └── requirements.md  ← spec quality checklist (all passing)
└── tasks.md             ← Phase 2 output (/speckit-tasks — NOT yet created)
```

### Source Code (repository root)

```text
TranslatorApp/
├── App/
│   ├── TranslatorAppApp.swift           — no changes
│   └── DependencyContainer.swift        — wire new parameters
├── Data/
│   ├── ContinuousSpeechListener.swift   — no changes (optional: make requiresOnDeviceRecognition configurable)
│   └── Respository/
│       └── SpeechRepository.swift       — no changes
├── Domain/
│   ├── Entities/
│   │   ├── SpeechSegment.swift          — no changes
│   │   ├── SpeechError.swift            — no changes
│   │   ├── QualitySnapshot.swift        — no changes
│   │   └── TranslatorState.swift        — no changes
│   ├── Interfaces/
│   │   ├── SpeechRepositoryProtocol.swift     — no changes
│   │   └── NLPSegmenterServiceProtocol.swift  — add committedFullText property
│   ├── Services/
│   │   ├── NLPSegmenterService.swift          — MODIFY: fix pendingSuffix, add maxFlushDelay
│   │   ├── QualityMetricsService.swift        — no changes
│   │   └── TranslationContextWindow.swift     — NEW: context window value type
│   └── UseCases/
│       └── TranscribeAudioUseCase.swift       — no changes
└── Presentation/
    ├── ViewModels/
    │   └── TranscriptionViewModel.swift       — MODIFY: tail display, full dedup, context window
    └── Views/
        ├── LiveTranscriptionView.swift        — MODIFY: context injection in .translationTask
        └── RecordButton.swift                 — no changes
```

**Structure Decision**: Single Xcode project, existing Clean Architecture layers preserved. One new file (`TranslationContextWindow.swift`) in the Domain/Services layer. All other changes are in-place modifications to existing files.

## Complexity Tracking

No Constitution violations to justify. All changes are within existing architectural patterns:
- New `TranslationContextWindow` is a plain `struct` (no actor, no class), consistent with existing entity conventions.
- `pendingSuffix` fix is a self-contained algorithm swap with identical in/out signature.
- Context injection in `.translationTask` follows the existing pattern of the modifier.
