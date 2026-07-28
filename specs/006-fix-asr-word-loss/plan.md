# Implementation Plan: Reconocimiento de voz sin pérdida de palabras

**Branch**: `006-fix-asr-word-loss` (spec on `develop`; feature dir `specs/006-fix-asr-word-loss/`) | **Date**: 2026-07-14 | **Spec**: [./spec.md](./spec.md)
**Input**: Feature specification from `specs/006-fix-asr-word-loss/spec.md` + `INFORME-DIAGNOSTICO-ASR.md`

## Summary

Fix the ASR word-loss and poor-recognition symptoms in four ordered phases. The
headline change is **closing the audio gap on recognizer restart** (H1) in the engine
that actually runs today (`LegacySFSpeechEngine → ContinuousSpeechListener`), plus three
cheap accuracy fixes (audio mode, request configuration, metrics de-contamination). A
measurement harness is wired first so every change is validated against a per-accent WER
baseline. Later phases make the premium WhisperKit engine viable on device (audio-format
conversion + streaming transcriber + real model management) and adopt the true iOS 26
`SpeechAnalyzer` as Tier 0 to remove the restart machinery at its root. The architecture
from feature 005 (pluggable `SpeechEngineProtocol`, `DependencyContainer` composition
root, actor-isolated engines) is **reused, not replaced**.

## Technical Context

**Language/Version**: Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency)
**Primary Dependencies**: SwiftUI · Speech (`SFSpeechRecognizer`; iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` in Phase 3) · AVFoundation (`AVAudioEngine`, `AVAudioConverter`) · NaturalLanguage (`NLTokenizer`/`NLTagger`) · Translation (Apple on-device) · WhisperKit (SPM, already present) · BackgroundAssets · OSLog · SwiftData
**Storage**: SwiftData (`ConversationRecord`, `SessionQualityRecord`); WhisperKit model files on disk in App Support. No new file types.
**Testing**: XCTest / Swift Testing. **New**: wire the existing `TranslatorAppEvaluationTests/` sources into a real evaluation test target (currently a member of no target). Preserve `TranslatorAppTests` and `TranslatorAppUITests`.
**Target Platform**: iPhone, `IPHONEOS_DEPLOYMENT_TARGET = 26.1`. iPad best-effort. macOS is a developer workstation only.
**Project Type**: Mobile app (single iOS app target).
**Performance Goals**: Zero word loss around pauses / the ~60 s restart (SC-001). Live ES output for confirmed WhisperKit segments within a 2-minute session without freeze (SC-007). 5-minute continuous SpeechAnalyzer session with no restarts (SC-009).
**Constraints**: 100 % offline at runtime (one-time consented model download only). Clean Architecture boundaries; Domain pure; ViewModels owned by composition root; capture+detection off MainActor; Swift-6 strict concurrency, no `@unchecked Sendable`; no new third-party dependencies beyond the present WhisperKit; ≤250 lines per Swift file.
**Scale/Scope**: 1 active session; <30 in-flight translation segments; ≤50 `SessionQualityRecord` rows.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-checked after Phase 1 design.*

There is no ratified constitution (`.specify/memory/constitution.md` is the unfilled template).
The **de-facto constitution** is `CLAUDE.md`'s Non-Negotiable Rules + the inner
`swift-app-traslator/CLAUDE.md` Key Design Decisions. Gates below are evaluated against those.

| Gate | Rule | Compliance | Status |
|---|---|---|---|
| G1 — Clean Architecture | `Presentation → Domain ← Data`; Domain imports only Foundation/CoreGraphics/simd/CoreMedia | All fixes stay within existing layers. New pieces (ring buffer, audio converter, `AudioStreamTranscriber` wrapper, real SpeechAnalyzer engine) live in `Data/`. Domain protocols/entities (`SpeechEngineProtocol`, `ModelInstallState`, `EngineId`) unchanged in dependency direction. | ✅ PASS |
| G2 — No `@StateObject` in Views | ViewModels owned only by composition root | No View ownership changes. Confidence-carrying fix is data-flow inside existing `TranscriptionViewModel` owned by `DependencyContainer`. | ✅ PASS |
| G3 — Threading | Capture+detection off MainActor; UI on MainActor | Engines remain actors; ring buffer + `AVAudioConverter` run on the capture path; harness on a test queue; only `@Observable` reads on MainActor. | ✅ PASS |
| G4 — Swift-6 strict concurrency | Build without concurrency warnings; no casual `@unchecked Sendable` | Ring buffer is actor-local state; converted buffers are value copies; no new `@unchecked`. | ✅ PASS |
| G5 — No new dependencies | OpenCV/manual xcframework rule (Aruco); here: no new SPM packages | WhisperKit already present; this feature **pins it to a released version** (reduces risk, adds nothing new). AVAudioConverter/SpeechAnalyzer are system frameworks. | ✅ PASS |
| G6 — ≤250 lines/file | Max 250 lines per Swift file | Consolidated classic engine and WhisperKit rewrite must respect this; split into `+Restart.swift` / `+Streaming.swift` if needed. | ✅ PASS (design constraint) |
| G7 — Physical/measurement honesty | README honest about trade-offs; measure before claiming | Phase 0 baseline + harness gate every claim numerically (SC-004, SC-010). | ✅ PASS |

**Result**: No violations. Complexity Tracking table not required.

## Project Structure

### Documentation (this feature)

```text
specs/006-fix-asr-word-loss/
├── plan.md              # This file
├── research.md          # Phase 0 — decisions per finding (H1–H5, W1–W6, cross-cutting)
├── data-model.md        # Phase 1 — entities added/changed
├── quickstart.md        # Phase 1 — how to validate each phase
├── contracts/           # Phase 1 — engine/audio contracts touched
├── checklists/
│   └── requirements.md  # spec quality checklist (from /speckit.specify)
└── tasks.md             # Phase 2 — created by /speckit.tasks (NOT here)
```

### Source Code (repository root)

```text
TranslatorApp/
├── App/
│   └── DependencyContainer.swift        # engine selection (:48–66); add engine-log; Tier-0 wiring (P3)
├── Domain/
│   ├── Interfaces/
│   │   └── SpeechEngineProtocol.swift   # unchanged contract; adapters conform
│   ├── Entities/
│   │   ├── EngineId.swift               # activate whisperKitSmall (P2 optional)
│   │   ├── ModelInstallState.swift      # reused for real progress (P2)
│   │   └── DeviceCapabilities.swift     # supportsEnhancedFrameworks gates Tier 0 (P3)
│   ├── Services/
│   │   ├── QualityMetricsService.swift  # H4: exclude partial confidence (:112, :56–60)
│   │   └── NLPSegmenterService.swift    # 1-word emit (:49–54); pendingHypothesis (:28)
│   └── UseCases/
│       └── TranscribeAudioUseCase.swift # confirmed-as-final flow (:48)
├── Data/
│   ├── ContinuousSpeechListener.swift   # H1 ring buffer + pre-primed request (:126–157)
│   ├── SpeechEngines/
│   │   ├── AppleSpeechAnalyzerEngine.swift  # H5 sync continuation (:37–39); consolidate/retire
│   │   ├── LegacySFSpeechEngine.swift        # route to consolidated engine
│   │   ├── WhisperKitEngine.swift            # W1 converter, W2/W3 AudioStreamTranscriber, W5 threshold
│   │   └── SpeechAnalyzerEngine.swift        # NEW (P3) real iOS 26 SpeechAnalyzer/SpeechTranscriber
│   ├── Audio/
│   │   ├── VADGate.swift                 # rename → EmptySegmentFilter; de-duplicate
│   │   └── AudioRingBuffer.swift         # NEW (P1) carry-over ring buffer for restart gap
│   ├── Coordinators/
│   │   └── BackgroundAssetsCoordinator.swift # W4: unzip + modelFolder or built-in download
│   └── SpeechRepository.swift           # remove duplicate VAD (:27); confidence tap (:38–50)
└── Presentation/
    ├── ViewModels/
    │   └── TranscriptionViewModel.swift # confidence bound to phrase (:65,164,178)
    └── Views/…                          # download progress UI reused (ModelInstallState)

TranslatorAppEvaluationTests/            # EXISTS on disk; Phase 0 wires it into a test target
├── Evaluation/ (WERCalculator, EvaluationHarness, …)
├── Tests/ (EdAcc, LibriSpeech, Reproducibility, …)
└── Tools/evaluation-delta/
```

**Structure Decision**: Reuse the feature-005 layout. This is a corrective feature: it edits
existing files behind the established `SpeechEngineProtocol` seam and adds only two new source
files (`AudioRingBuffer`, `SpeechAnalyzerEngine`) plus the evaluation test target wiring. No new
layers, no restructuring.

## Phased Delivery

Phases map 1:1 to the spec's User Stories and priorities. Each phase is independently
shippable and independently testable.

### Phase 0 — Measure first (US3, 🟠) — *gates everything below*
- Wire `TranslatorAppEvaluationTests/` into a real Xcode test target + scheme (005 T003).
- Establish **baseline WER per accent group** from a mini-corpus (XCTSkip when corpus absent).
- Add an unambiguous `[Container] engine=…` OSLog line at `DependencyContainer` init.
- **Exit gate**: `xcodebuild test -only-testing:TranslatorAppEvaluationTests/…` runs; baseline JSON recorded.

### Phase 1 — Fix the engine people use today (US1 + US2, 🔴) — *highest return*
- H1: `AudioRingBuffer` (~1.5 s) + create/start new request before ending old, replay carry-over.
- H2: `.measurement` → `.spokenAudio` (fallback `.default`).
- H3: `taskHint = .dictation`, `addsPunctuation = true`, `contextualStrings`.
- H4: exclude partial-result confidence from `QualityMetricsService`.
- H5: synchronous continuation assignment in `AppleSpeechAnalyzerEngine`.
- Consolidate the two classic engines into one; retire the duplicate.
- Cross-cutting: 1-word emit, confidence-bound-to-phrase.
- **Exit gate**: SC-001 = 0 % restart loss on the scripted corpus; SC-002 WER improves vs baseline for non-native + low-voice groups with **no** native regression beyond noise (SC-010); SC-003 one-word utterances appear.

### Phase 2 — Make WhisperKit viable (US4, 🟡)
- W1: native-format tap + `AVAudioConverter` → 16 kHz mono.
- W2/W3/W6: adopt `AudioStreamTranscriber`, emit confirmed segments as `isFinal`.
- W4: unify model management (built-in download w/ progress → `ModelInstallState`, preload on
  engine-select, unzip if BackgroundAssets path kept, correct URL, **pin SPM to a version**).
- W5: remove/relax `firstTokenLogProbThreshold`.
- Rename/de-duplicate VAD; optionally evaluate `small`/`distil` via the harness.
- **Exit gate**: capture works on device (no format crash); live ES output before stop;
  2-minute session no freeze (SC-007); model preloaded with visible progress (SC-008).

### Phase 3 — iOS 26 SpeechAnalyzer as Tier 0 (US5, 🟠)
- New `SpeechAnalyzerEngine` using the real `SpeechAnalyzer`/`SpeechTranscriber`.
- Select as Tier 0 via `supportsEnhancedFrameworks`; transparent fallback otherwise.
- **Exit gate**: SC-009 — 5-minute continuous session, no restarts, no word loss.

## Phase 0/1 Design Outputs

- `research.md` — every finding resolved with Decision / Rationale / Alternatives / anchor.
- `data-model.md` — new `AudioRingBuffer`; reused `ModelInstallState`, `EngineId`,
  `SpeechSegment`; metric/segmenter rule changes.
- `contracts/` — `SpeechEngineProtocol` (unchanged, restated), `AudioRingBuffer` contract,
  `EmptySegmentFilter` (renamed VAD) contract, WhisperKit streaming adapter contract.
- `quickstart.md` — per-phase validation recipes (device + harness).

## Complexity Tracking

No constitution violations to justify — table intentionally omitted.

## Open Questions for `/speckit.clarify` (non-blocking)

1. **Feature split**: keep US4 (WhisperKit) and US5 (SpeechAnalyzer) in this feature, or split
   into `007`/`008` so Phase 1 ships fast? Recommended: land Phase 0+1 here; consider splitting
   Phase 2/3 if scheduling pressure appears.
2. **Git branch**: create `006-fix-asr-word-loss` or continue on `develop`? (Project rule:
   no branch without asking — currently unresolved; spec/plan authored on `develop`.)
3. **Model management path** (W4): WhisperKit built-in download vs. fix the BackgroundAssets
   coordinator. Recommended: built-in download with progress → existing `ModelInstallState` UI,
   retire the coordinator's unused artifact.
