# TranslatorApp Constitution

Derived from the project rules already in force in `CLAUDE.md`. Written during feature
008-fix-audio-pipeline-resilience, whose `plan.md` had to declare that this file was an
unfilled template and that its gates therefore carried no weight.

## Core Principles

### I. Clean Architecture, one direction

`Presentation → Domain ← Data`. `App` is the only layer aware of all three.

`Domain` imports **only** `Foundation` (plus `OSLog` for logging). It must never import
AVFoundation, Speech, SwiftUI, UIKit or SwiftData. Framework types stop at the layer boundary:
errors cross as `(domain: String, code: Int)`, audio causes as domain enums.

Violations to reject: `Presentation` importing `Data`; `Domain` importing a framework;
Views creating ViewModels with `@StateObject`.

### II. Composition root owns the graph

`DependencyContainer` constructs every long-lived instance in `init()`. ViewModels are owned
only there and passed into Views. No singletons, no global mutable state.

### III. The MainActor is for UI only

`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` means everything is MainActor-isolated unless it
says otherwise. Anything reached from an actor or from the audio render thread must be
explicitly `nonisolated` — including static members and, where needed, whole classes.

Nothing over ~5 ms runs on the MainActor. Nothing that allocates, locks for long, or awaits
runs on the audio render thread.

### IV. Build clean under strict concurrency (NON-NEGOTIABLE)

Zero concurrency warnings. When one appears, fix the isolation; do not silence it.

`@unchecked Sendable` requires a written justification in the file header naming what provides
safety instead of the actor system, and what the lock is and is not held across. It is
currently used exactly twice, both on the audio path.

### V. Absence must be visible

A failure that produces no artefact is worse than a loud one. A dropped translation carries a
marker and keeps its line; a session that dies logs its error domain and code; a suspended
recording says it is suspended. Silent truncation, empty catches, and states indistinguishable
from success are defects regardless of what the code "does".

### VI. Instrument before you claim

An intermittent symptom is not fixed until the fix is observable in the field. Structured
telemetry (`Telemetry` category, `[KIND] sid=… key=value`) is part of the feature, not a
follow-up. Event prefixes are a published interface: renaming one breaks every saved filter.

Telemetry never blocks, never throws, and never carries transcribed text.

## Additional Constraints

- **Platform:** iOS/iPadOS 26.1+, Swift 5 language mode. Pure Xcode project; the file-system
  synchronized groups mean new files join their target without editing `project.pbxproj`.
- **No new dependencies.** No package managers beyond what is already present.
- **Max 250 lines per Swift file.** Split by responsibility, not by cutting arbitrarily.
- **Logging:** `OSLog`, subsystem `com.spanesso.TraslatorApp`, one category per component.
- **Language pair** is `en-US → es-ES`. Transcription and translation stay on-device.

## Development Workflow

- **Validate on a physical device.** The simulator does not reproduce `AVAudioSession`
  behaviour, interruptions, or route changes — precisely the areas that keep breaking.
- **Capture a baseline before changing anything.** A measurement you cannot compare against is
  an impression.
- **Pure logic goes in `Domain` and gets unit tests** in `TranslatorAppTests`. If a rule cannot
  be tested without audio hardware, it is probably in the wrong layer.
- **Every regression that reached a user earns a test** that fails on the old code.

## Governance

This constitution supersedes habit. Amendments require updating this file and `CLAUDE.md`
together.

Non-negotiable operational rules:

1. **No commits.** The user handles all git manually.
2. **No creating branches without asking** the name and whether to stay on the current one.
3. **No pushing.** The user owns the remote.

Complexity must be justified in writing, in the plan that introduces it. "It is cleaner" is not
a justification; "it removes a duplicate that already diverged once" is.

**Version**: 1.0.0 | **Ratified**: 2026-07-28 | **Last Amended**: 2026-07-28
