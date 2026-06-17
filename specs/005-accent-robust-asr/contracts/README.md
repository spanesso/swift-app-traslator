# Contracts — feature 005-accent-robust-asr

Swift protocol files defining the **Domain-layer surface** for this feature.
They are the contract concrete adapters (in `Data/`) must satisfy.

> **These files are SPEC ARTIFACTS, not compile units.** They live outside any Xcode build target. SourceKit will (correctly) flag "Cannot find type 'EngineId'", etc. — that is expected because the entity types defined in `data-model.md` (TranscriptToken, EngineId, AccentGroup, EnginePreference, ModelInstallState) don't yet exist as Swift files. They will be created in the implementation phase (`/speckit-tasks` → `/speckit-implement`) and these protocol files will be copied verbatim into `TranslatorApp/Domain/Interfaces/`. Until then, treat the diagnostics as informational.

| File | Purpose |
|---|---|
| `SpeechEngineProtocol.swift` | Pluggable ASR engine — implemented by `AppleSpeechAnalyzerEngine`, `WhisperKitEngine`, and (as fallback) the existing `ContinuousSpeechListener`-backed legacy adapter. |
| `TranscriptCorrectorProtocol.swift` | Post-correction stage with hard anti-hallucination invariants. Implemented by `FoundationModelsCorrector`. |
| `ModelDownloadCoordinatorProtocol.swift` | Lifecycle of the WhisperKit on-device model download (Background Assets framework underneath). |
| `EvaluationHarnessProtocol.swift` | Test-target-only harness that runs the live pipeline against a labeled corpus and emits the SC-001..SC-010 report. |

### Boundaries

- **Pure Domain**: no `import Speech`, no `import AVFoundation`, no `import WhisperKit`, no `import FoundationModels`, no `import SwiftUI`. The CLAUDE.md non-negotiable rule "Domain layer pure" applies as-is.
- **All types `Sendable`**: this feature targets Swift strict concurrency. Any non-`Sendable` adapter type must be wrapped in an actor.
- **`SpeechEngineProtocol` does not replace `SpeechRepositoryProtocol`** — `SpeechRepositoryProtocol` continues to exist as the use-case-facing surface; the new `SpeechRepository` implementation delegates to an `SpeechEngineProtocol` adapter selected at composition time.

### Files this introduces in `TranslatorApp/`

These files are copied verbatim from this directory into the project structure:

```
TranslatorApp/Domain/Interfaces/SpeechEngineProtocol.swift
TranslatorApp/Domain/Interfaces/TranscriptCorrectorProtocol.swift
TranslatorApp/Domain/Interfaces/ModelDownloadCoordinatorProtocol.swift
TranslatorAppTests/EvaluationHarness/EvaluationHarnessProtocol.swift
```
