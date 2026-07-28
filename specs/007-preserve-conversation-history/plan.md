# Implementation Plan: Preserve Full Conversation History

**Branch**: `007-preserve-conversation-history` | **Date**: 2026-07-22 | **Spec**: [spec.md](./spec.md)
**Input**: Feature specification from `/specs/007-preserve-conversation-history/spec.md`

## Summary

While an ASR session is active, the live transcription (EN) and translation (ES) panes
silently drop the oldest content once fixed in-memory caps are reached
(`maxEmitted = 50` phrases, `maxTranslated = 30` sentences, both trimmed via
`removeFirst()` in `TranscriptionViewModel`). The user experiences this as "the beginning
of the conversation disappears when I scroll up." The fix removes the destructive trimming
so the full session history is retained in order, and hardens the live-update and scroll
paths so an unbounded (but realistically small) history stays smooth for long sessions.
No change is needed to the speech engines, segmenter, translation pipeline, or Save/Export
logic beyond removing the caps — Save/Export already serialize the full arrays and become
complete automatically once trimming is gone.

## Technical Context

**Language/Version**: Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency)  
**Primary Dependencies**: SwiftUI, Speech (`SFSpeechRecognizer`), AVFoundation, NaturalLanguage, Translation (Apple on-device), SwiftData, OSLog  
**Storage**: In-memory per live session (`TranscriptionViewModel` arrays). Persistence of a finished session is existing SwiftData Save/Export — unchanged.  
**Testing**: XCTest (`xcodebuild test`); manual on-device verification for long-session scroll behavior  
**Target Platform**: iOS (iPhone) — per feature line 005/006; live transcription screen  
**Project Type**: Mobile app (Clean Architecture: Data → Domain → Presentation)  
**Performance Goals**: Live auto-follow latency unchanged; UI stays at interactive frame rates while scrolling a full session (≥ 100 phrases, 30+ min)  
**Constraints**: No regression to auto-follow, duplicate suppression, confidence styling, restart/continuity, or Save/Export; MVVM/Clean-Architecture rules from `CLAUDE.md`; must build without new concurrency warnings  
**Scale/Scope**: A single active recording session. Realistic upper bound: a few thousand phrases (multi-hour session). Text volume is tiny (< a few MB), so memory is not the constraint — render/update cost is.

## Constitution Check

*GATE: Must pass before Phase 0 research. Re-check after Phase 1 design.*

The project constitution (`.specify/memory/constitution.md`) is an unfilled template with no
ratified principles, so there are no formal gates to evaluate. In their place, the de-facto
constraints from `CLAUDE.md` are applied as gates:

- **Clean Architecture dependency rule** (`Presentation → Domain ← Data`): PASS — the change is
  confined to the Presentation layer (`TranscriptionViewModel` + live panes). No Domain/Data edits.
- **MVVM ownership** (ViewModels owned only by composition root): PASS — no ViewModel ownership change.
- **No new dependencies**: PASS — no packages added.
- **Strict concurrency, MainActor discipline**: PASS — history mutation stays on `@MainActor`
  in the ViewModel; no new cross-actor hops. Any hot-path optimization must not move work onto
  or block the MainActor beyond what already happens per ASR update.
- **File size / organization** (split large files): PASS — no file expected to exceed limits;
  panes already split into `LiveTranscriptionPanes.swift`.

**Result**: No violations. Complexity Tracking section is empty.

## Project Structure

### Documentation (this feature)

```text
specs/007-preserve-conversation-history/
├── plan.md              # This file
├── research.md          # Phase 0 output
├── data-model.md        # Phase 1 output
├── quickstart.md        # Phase 1 output
├── contracts/           # Phase 1 output (UI/state contract)
│   └── viewmodel-history-contract.md
├── checklists/
│   └── requirements.md  # From /speckit.specify
└── tasks.md             # Created later by /speckit.tasks
```

### Source Code (repository root)

```text
TranslatorApp/
├── Presentation/
│   ├── ViewModels/
│   │   └── TranscriptionViewModel.swift      # PRIMARY CHANGE: remove maxEmitted/maxTranslated trimming;
│   │                                         #   guard hot-path cost of committed-prefix computation
│   └── Views/
│       ├── LiveTranscriptionView.swift       # unchanged (host view)
│       └── LiveTranscriptionPanes.swift      # SECONDARY: LazyVStack for growing history + stable IDs
├── Domain/                                   # unchanged
└── Data/                                     # unchanged
```

**Structure Decision**: Existing iOS Clean-Architecture layout. The fix is Presentation-only.
The single source of truth for session history is `TranscriptionViewModel.emittedPhrases`
(EN) and `TranscriptionViewModel.translatedSentences` (ES); the panes render them read-only.

## Complexity Tracking

> No constitution violations. Section intentionally empty.
