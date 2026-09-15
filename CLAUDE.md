# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

This is a pure Xcode project — there is no `Makefile`, `Package.swift`, or CLI build script.

- **Open project:** `open TranslatorApp.xcodeproj`
- **Build from CLI:** `xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO`
- **Run unit tests:** `xcodebuild test -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -only-testing:TranslatorAppTests`

**Platform: iOS/iPadOS 26.1+** (`IPHONEOS_DEPLOYMENT_TARGET = 26.1`, `TARGETED_DEVICE_FAMILY = "1,2"`). Needs microphone + speech recognition permissions at runtime. Declares the `audio` background mode so capture survives a locked screen (008 decision Q3).

The Xcode project uses `PBXFileSystemSynchronizedRootGroup`: **new `.swift` files under `TranslatorApp/` and `TranslatorAppTests/` are added to their target automatically** — `project.pbxproj` does not need editing.

Behaviour that needs real hardware — interruptions, route changes, background capture — is validated by hand; see `specs/008-fix-audio-pipeline-resilience/quickstart.md`.

## Architecture

The app follows Clean Architecture with three layers wired together by `DependencyContainer`:

```
Data  →  Domain  →  Presentation
```

### Data Layer
- **`ContinuousSpeechListener`** (Swift `actor`) — wraps `SFSpeechRecognizer` and `AVAudioEngine`. Produces an `AsyncStream<SpeechSegment>` of partial and final ASR results. Also records quality metrics on every transcript update. Calls `continuation.finish()` in `stop()` before setting it to `nil` — this is required for downstream `for await` loops to terminate.
- **`AppleSFSpeechEngine`** (`actor`) — the single ASR engine, wrapping `SFSpeechRecognizer` with on-device recognition. Consolidates the three near-duplicate engines that existed before 008 (`ContinuousSpeechListener`, `LegacySFSpeechEngine`, `AppleSpeechAnalyzerEngine`), which had already diverged: only one had a watchdog, only another closed the stream when a restart failed. Split across `+Rotation` (recogniser swap, watchdog), `+Resilience` (audio-system events), `+Shutdown` (stop that waits for the final result) and `+Policy` (request construction, replay windows — pure and tested).
- **`AudioCaptureSession`** (`actor`) — owns `AVAudioEngine` and the microphone tap. **The tap is installed once per recording session**; recogniser rotation never touches it. Rebuilt only on a route or configuration change, always reading the input format at install time.
- **`RecognitionRequestBox`** — lock-protected, swappable holder for the active recognition request. Readable from the audio render thread without `await`; this is what makes rotation a pointer swap.
- **`AudioSessionCoordinator`** (`actor`) — the single owner of `AVAudioSession` and of every audio notification (interruption, route change, configuration change, media-services reset). Emits `AudioSessionEvent`s upward.
- **`AudioRingBuffer`** (`nonisolated final class`) — preallocated carry-over window (6 s). The tap only does `memcpy`; it reallocates only when the input format or buffer size changes. `drain(lastMs:)` returns just the newest audio a rotation needs. Written through `RecognitionRequestBox.append(_:recordingInto:)` so request and window are updated under one lock.
- **`TapStallDetector`** — pure; turns "no buffers reached the tap" into `TAP_STALL`. Silence still arrives as buffers; their absence is a dead capture path.
- **`BackupExclusion`** — excludes Application Support (SwiftData store + live journal) from device backups.
- **`FileTranscriptJournal`** (`actor`) — append-only, crash-safe journal of the meeting in progress. Written on every confirmed phrase and every translation outcome; recovered on launch; deleted only when the user saves (after the store accepted it) or discards. Not encrypted per phrase by decision — it is temporary and protected by iOS file protection.
- **`Data/Security/`** — `ConversationEnvelope` (ECIES sealing of a whole conversation), `SecureEnclaveDeviceKey` / `SoftwareDeviceKey`, `ConversationKeychain` (load-or-create, never replace), `HybridConversationSealer` (conforms to Domain's `ConversationSealingProtocol`).
- **`PipelineTelemetry`** — structured OSLog telemetry, category `Telemetry`.
- **`SpeechRepository`** — thin adapter conforming to `SpeechRepositoryProtocol`; applies `EmptySegmentFilter` once for every engine and records quality signals.

### Domain Layer
- **`SpeechSegment`** — value type carrying `text`, `isFinal`, `confidence`, `tokens`, and `sessionGeneration` (which recognition session produced it).
- **`ConversationFragment`** — the paired unit of a conversation: source text plus a `TranslationOutcome` (`pending` / `translated` / `unavailable(reason)`). In memory only.
- **`RecordingSessionState`** — `idle` / `active` / `suspended(reason)` / `stopping`. `suspended → idle` is illegal by construction.
- **`LiveTailReconciler`** — pure, unit-tested computation of the live English tail against the CURRENT recognition session's baseline.
- **`ConversationTextFormatter`** — the only producer of conversation text; guarantees both language blocks have the same line count.
- **`TranscriptJournalEntry` / `RecoveredSession`** — one durable record per phrase or translation outcome, and the meeting reconstructed from them. Each entry is written exactly once and is independent, which is what makes a torn journal recoverable.
- **`TranscribeAudioUseCase`** — orchestrates the pipeline. The primary entry point is `executeBoth()`, which starts transcription and uses a stored detached pump `Task` to fan-out one source `AsyncStream<SpeechSegment>` into two independent streams (raw + segmenter input). `AsyncStream` is single-consumer — using it with two concurrent `for await` loops distributes elements unpredictably. `stop()` stops the repository FIRST and then waits (bounded) for the pump to drain — it never cancels the pump up front.
- **`NLPSegmenterService`** (`actor`) — differential segmentation using a 3-tier cascade: (1) NLTokenizer detects complete sentences and emits all but the last; (2) tails longer than 15 words are cut at the last clause marker (punctuation or discourse connector); (3) a silence-triggered stability timer (0.7 s normal / 1.2 s low-quality) fires when ASR stabilizes without a terminator. Emits only new deltas (≥ 2 words) over already-committed text. `isLowQualitySpeech()` from `QualityMetricsService` adapts the timer duration.
- **`QualityMetricsService`** (`actor`) — tracks ASR quality signals per session: revision rate, stability delay, words-per-second, confidence, fragmentation. `isLowQualitySpeech()` is consumed by `NLPSegmenterService` for adaptive delay tuning.

### Presentation Layer
- **`TranscriptionViewModel`** (`@Observable`, `@MainActor`) — owns `fragments: [ConversationFragment]` and `sessionState`. Split across `+Session` (start, suspension, raw-stream handling), `+Shutdown` (stop, restart, failure teardown), `+Fragments` (commit, translation resolution, drain), `+Archive` and `+Recovery`. `stopRecording()` lets the last phrase become a fragment, then drains in-flight translations for up to 3 s before closing.
- **`LiveTranscriptionView`** — split-pane SwiftUI view (35 % EN / 60 % ES). Uses `.translationTask` modifier (Apple `Translation` framework, `en-US → es-ES`, offline-capable) to consume `translationRequests`. **`taskID` is rotated before `translationConfig` is assigned** when recording starts — this is required to destroy the stale `.translationTask` subtree from the previous session.
- **`RecordButton`** — standalone record toggle component.

### Dependency wiring
`DependencyContainer` owns all long-lived instances and constructs the full graph in `init()`, including a **cached `TranscriptionViewModel`** returned by `makeTranscriptionViewModel()`. `TranslatorAppApp` holds a single `@State private var container` so the graph lives for the app session. There are no singletons or global state anywhere in the codebase.

## Non-Negotiable: everything runs on-device

**No audio and no text belonging to the user ever leaves the device.** Fixed 2026-07-29.

This is a meeting app; the recordings are real, potentially confidential work conversations, and the interface promises "OFFLINE TRANSLATION". Treat it as an architectural constraint, not a preference.

Hardened 2026-09-15: **nothing of a conversation leaves the app unless the user shares it.** No automatic path may send it to a third party or a backend.

- `requiresOnDeviceRecognition = true` **unconditionally** (`AppleSFSpeechEngine.makeRequest`). If `supportsOnDeviceRecognition` is false, recording does not start (`SpeechEngineError.onDeviceRecognitionUnavailable`). Until 2026-09-15 the flag followed `supportsOnDeviceRecognition`, which silently meant "use the server" on a device without local support. Apple's **server-based recognition is off the table** — not as a setting, not as a fallback, not "only when there is a network".
- Translation stays on Apple's on-device `Translation` framework.
- Telemetry is local `OSLog` only. Nothing is ever uploaded. **No log line may contain conversation text** — counts only (the corrector and loop detector used to log phrases).
- **Device backups are an automatic upload:** Application Support and the journal directory are marked `isExcludedFromBackup`. Accepted consequence: saved meetings do not survive a restore from backup.
- **Sharing is the only way out, and only by the user's hand.** Export is available whether the meeting is saved or not.
- **A saved conversation is readable only by its user — not by the app on its own.** It is sealed ONCE, as a whole (not phrase by phrase), with hybrid ECIES: ephemeral P-256 + HKDF-SHA256 + AES-256-GCM to a **Secure Enclave** key (`ConversationEnvelope`, `SecureEnclaveDeviceKey`). Sealing uses only the public half, so saving never prompts and never fails for lack of Face ID. Opening needs the private half, released only after `deviceOwnerAuthentication` (Face ID / Touch ID / passcode). The history lists `ConversationSummary` (id + date) and never decrypts; the decrypted conversation lives in `ConversationHistoryViewModel.openedConversation` only while on screen. Stored in the existing `englishText` field as `sealed-v1:<base64>` with `spanishText` empty — no schema migration (Q2). Earlier plaintext records are sealed at launch.
- **`ConversationKeychain` never replaces an existing key.** Every saved conversation depends on it; a key is created only when the keychain reports `errSecItemNotFound`, never after any other failure (a locked device would otherwise orphan every saved meeting). Item is `AfterFirstUnlockThisDeviceOnly`, not synchronizable. Without a device passcode the Secure Enclave key is created without user presence (still device-bound) so saving always works; the simulator uses a software key.
- **Accepted consequences:** deleting the app or restoring the device from a backup makes saved conversations unreadable. Old plaintext pages may linger in SQLite free space until reused (still under iOS file encryption).
- **The only permitted network traffic is downloading resources TO the device** — e.g. the WhisperKit model in `BackgroundAssetsCoordinator`. The distinction is direction: pulling models down is fine, sending audio or text up never is.

**Consequence for accuracy work:** when recognition misses a quiet speaker, the answer cannot be a remote model. The available levers are microphone configuration (polar pattern — currently untouched), making the input level visible so the user can react during the meeting, and reinstating WhisperKit properly, which is local and more robust at low signal-to-noise than Apple's on-device model.

## Key Design Decisions

- **The tap is permanent (008):** recogniser rotation swaps the request inside `RecognitionRequestBox`; it never calls `removeTap`/`installTap`. Before 008 the tap was rebuilt on every rotation, and between the two calls nothing was capturing — not the request, not the carry-over buffer. Expected `blindMs` in the `TAP_SWAP` telemetry is **0**, not "small". Never reintroduce a tap teardown on the rotation path.
- **On-device recognition (008, made unconditional 2026-09-15):** `requiresOnDeviceRecognition = true`, and no recording without local support. It removes the ~1-minute server audio limit that forced constant rotation, and the whole class of network errors that were invisible because the error code was never read.
- **An interruption suspends, it does not stop (008):** `RecordingSessionState.suspended` keeps the stream open, the history intact and the audio session ACTIVE. `setActive(false)` must never be called while suspended — that is what allows resuming. Recovery uses the end-of-interruption notification **plus a 2 s reactivation poll**, because iOS does not reliably deliver that notification; a successful `setActive(true)` is the real proof the interruption ended. This is what recovers an alarm or a call the user never touched.
- **Never report an audio interruption as a permissions problem (008):** it was, and the message was false. `TranslatorState.suspendedByAudioInterruption` and a banner replace that alert.
- **Reschedule the stability timer on every early return (008):** `NLPSegmenterService` cancels it before several `continue` paths. All of them go through `reschedule(...)`. The critical one is the duplicate-partial path: the recogniser re-emits the same text while the speaker pauses, and each repeat used to kill the pending emission — the phrase was then never translated. The `STAB_CANCEL` telemetry carries `rescheduled`; a `false` with a non-empty tail means the bug is back.
- **The recogniser restarts its transcript WITHOUT telling anyone (field, 2026-08-05):** on iOS 26 on-device recognition, `SFSpeechRecognizer` discards its transcript at an utterance boundary — typically a change of speaker — with no final result, no error and no end of task. `sessionGeneration` therefore does not change and the generation check cannot see it. `NLPSegmenterService.didRestartTranscript` detects it by comparing against the PREVIOUS TEXT (a collapse to under half the word count), flushes the stranded pending tail immediately, and resets the baseline while KEEPING `committedTailWords` so the words spanning the boundary are not shown twice. Never assume one monotonically growing string per generation.
- **A stale baseline must always have a way out (field, 2026-08-05):** `pendingSuffix` returned `""` whenever the committed text could not be found in the recogniser's window, guarded only by `window.count * 2 < committedWordCount` — a test that can only get FALSER as the window grows. Once it went stale the segmenter emitted nothing for the rest of the meeting, silently. It is now bounded by `maxAnchorMisses`. Any "wait for the next update" branch needs a bound; without one it is a permanent stall waiting to happen.
- **A silent recogniser is not a silent room (field, 2026-08-05):** `RECOGNIZER_DEAF` fires when no transcript has arrived for 4 s **and** `AudioLevelMonitor` still reports speech energy, and rotates. Field traces showed 14 consecutive seconds of speech-level audio with no partial, no final, no error and no rotation — the 65 s watchdog is tuned for "the session died" and cannot see this. Rotating is the remedy because rotation is free here (permanent tap, `blindMs=0`). A deaf rotation replays **everything since the last transcript + 500 ms** (window 6 s); every other rotation replays 1.5 s. Until 2026-09-15 it replayed 1.5 s, so a 4 s deaf rotation threw away ~2.5 s of the speech it existed to recover. Backs off to 16 s while rotations fail to bring the text back, and resets on any transcript.
- **Quality classification is one live term, with hysteresis and a warm-up (field, 2026-08-05):** `isFinal` effectively never fires with on-device recognition, so `confidenceScores` stays empty and the confidence term is inert; `isLowQualitySpeech()` is in practice a test on `revisionRate`. Do not read the three-term expression as if all three were live on this platform. Three calibration rules, each from a trace:
  - The ceiling of 10/min classified every real meeting as low quality and pinned the delay at 1 200 ms so the 700 ms path never ran. A working meeting sits around 35/min.
  - It takes 45/min to ENTER low quality and it stays there until it drops under 35/min. With one threshold at the operating point the verdict flipped 34.4 → 36.5 → 34.7 inside a minute, moving the emission delay half a second each time.
  - Nothing is judged before 20 s and 25 observations. `revisionRate` divides by elapsed session time, so one revision two seconds in reads as 30/min; every meeting used to open at `revRate=85.0` and LOW, applying the slowest delay exactly where the first phrases arrive.

  The verdict lives in the pure `QualityMetricsService.classify(revisionRate:fragmentation:confidence:wasLow:)` so the calibration is testable without a clock or a session.
- **Reconcile against the recognition session, not the meeting (008):** `LiveTailReconciler`'s baseline resets on every rotation, signalled by `SpeechSegment.sessionGeneration`. Comparing incoming text against the whole meeting's committed text froze the English pane permanently about a minute in, because a ~60 s recognition session can never out-count the whole meeting.
- **A fragment never disappears (008):** a failed, empty, too-short or timed-out translation becomes `.unavailable(reason)` and still occupies its line. Both exported blocks use the same separator and always have the same line count; `SaveConversationUseCase` refuses to persist misaligned blocks. Absence must be a visible marker, never a missing row.
- **The transcript is durable from the instant it exists (010):** every confirmed phrase and every translation outcome is appended to a crash-safe journal on disk BEFORE anything else happens. One JSON object per line, flushed immediately, so a process killed at any moment can only damage the last line. The journal is deleted only after the user saves (and the store accepted it) or explicitly discards. Never make the transcript depend on the process staying alive — it used to, and a user lost a real meeting to it.
- **Nothing may lose what has been said so far (durability audit, 2026-09-15).** Rules, each with a test that failed before it:
  - Record and Save are refused while `sessionState == .stopping`: the last phrase and translations are still arriving. The consumer checks `sessionEpoch` before acting, so a consumer outliving its session never stops or writes into the next one.
  - At stop (and restart), words still on screen that the pipeline never committed become the last phrase (`commitUnconfirmedTail`).
  - The journal queues every entry before writing and drops it only once on storage (`F_FULLFSYNC`, fallback `fsync`); a failed write is retried with the next entry, and a write cut short is truncated back to the last whole line.
  - `discard()` remembers the session; a late entry of a saved or discarded meeting never recreates its journal.
  - A journal that exists but cannot be read is moved to `LiveTranscript/Unreadable/`, never deleted.
  - Discarding the unfinished meeting found at launch needs a second confirmation.
  - Recovered phrases whose translation was missing are translated again (on-device) instead of staying "unavailable".
  - If the SwiftData store cannot be opened, the app starts with an in-memory stand-in instead of `fatalError`, so recovery still runs; saving then fails loudly (`ConversationStoreError.storeUnavailable`) and the journal is kept.
- **The phrase in progress is on disk too (2026-09-15):** an out-of-memory termination runs no code, and the words not yet committed used to live only in memory (up to ~3 s). `TranscriptionViewModel+Draft` journals the live text as `draft` entries at most once a second while it changes, and immediately on a memory warning (`MEMORY_WARNING`) or when the app leaves the foreground. Recovery keeps only the newest draft past the last committed phrase; a `source` with the same id supersedes it, and a draft that only repeats the phrase just committed is never written. A meeting killed before its first committed phrase is recovered from its draft.
- **The user decides what happens to a finished meeting (2026-09-15, replaced 010's automatic archiving):** stopping saves NOTHING and discards NOTHING (`meetingDidEnd`). The meeting stays on screen with an "not saved yet" banner and Save / Export / Discard. Save seals and stores it, and only then deletes the journal; a failed save keeps both. Discard requires a confirmation. Until the user decides, the plaintext journal (iOS file protection, excluded from backups) is the crash-safe copy and recovery offers it on the next launch. Starting a new recording over an unsaved meeting offers "Save and start new" / "Discard and start new"; the record button does nothing while a recovery prompt is pending, and a leftover journal must be recovered or discarded before a new one opens (`startRecordingUnlessAMeetingIsPending`). The journal also refuses to append one session's entries into another session's file (they used to be mixed on recovery). **The conversation is never lost without an explicit user choice.**
- **Stopping must not lose the last phrase (2026-09-15):** order is engine stop → `endAudio()` → wait up to 1.5 s for the final result → finish the stream → pump drains → segmenter flushes → the still-alive consumer commits. The consumer used to be cancelled first, so the phrase in progress at every stop was emitted into a stream nobody read. `restartListening` follows the same order and sets `isRestartingListening` so the old consumer ending is not read as the session ending.
- **A stop can land in the middle of a start (field, 2026-09-15):** `AppleSFSpeechEngine.start()` suspends several times (authorization, session activation, capture). A stop in one of those gaps used to set its flags and then be undone as `start()` resumed and went live: the microphone kept capturing with the interface idle, and the next meeting replayed that audio and was rotated 24 ms in by the orphaned task's closing error. Now every `stop()` bumps `lifecycleEpoch` (BEFORE its `isStopping` guard), `start()` abandons if it changed, and callbacks carry `sessionOrdinal` because `generation` restarts at 0 each session. Signature in the log: `SESSION_END sid=----`.
- **Duplicates are recent echoes, not repeated words (2026-09-15):** `RecentPhraseFilter` drops a phrase only if it has ≥3 words and matches one of the last 3 within 15 s. The old whole-meeting set dropped every second "Okay." / "Thank you." before it was journaled.
- **Segmenter: nothing may be skipped (2026-09-15):** a generation change FLUSHES the pending tail before resetting and KEEPS `committedTailWords` (replayed audio is trimmed, not shown twice); the sentence loop stops at the first sentence too short to emit (standalone replies are forced) instead of skipping it; every armed tail is under the 3 s ceiling; an anchor miss with `totalWords >= committedWordCount` resumes from position instead of re-emitting the utterance. Each rule has a test in `SegmenterWordLossTests` that fails without it.
- **File protection class is load-bearing (010):** the journal is created with `.completeUntilFirstUserAuthentication`. The default class would refuse writes with the screen locked, which is precisely the state feature 008 decision Q3 introduced.
- **Unbounded in-session history (007, preserved in 008):** `fragments` is append-only for the whole recording session. It is cleared only when a NEW (non-continuing) session starts. Never reintroduce a `removeFirst()` trim — that silently discarded the start of the conversation.
- **Fan-out pump Task:** `executeBoth()` creates a `Task.detached` pump that forwards each segment to two separate `AsyncStream.Continuation` objects. `stop()` waits for it to drain (`TaskCompletion.wait`, 1 s) and cancels it only on timeout.
- **Actor isolation and `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`:** every type that is touched from the audio render thread or from an actor needs explicit `nonisolated` — including static members and whole classes (`nonisolated final class AudioRingBuffer`). Without it the compiler warns and the isolation is genuinely wrong, not merely noisy. Static stored properties whose initializer is not a compile-time literal become MainActor-isolated; prefer `nonisolated static var x: T { ... }`.
- **The translation consumer follows the STREAM, not the record button:** the view rotates its `.translationTask` on `onChange(of: viewModel.translationStreamId)`, and `startRecording` publishes a new id on EVERY start. Keyed on `isRecording` it was wrong for the one case that matters: `restartListening()` replaces the request stream while the session stays recording, so `isRecording` never changed, no new consumer was created, and every phrase from that tap onwards sat on "Translating…" for the rest of the meeting — with no error anywhere. The `.translationTask` lives on its own invisible 1×1 node so rotating the id does not rebuild the panes.
- **taskID rotation ordering:** `taskID = UUID()` MUST be assigned before `translationConfig = .init(...)`, so SwiftUI destroys the old `.translationTask` subtree before the new config starts a task.
- **Asynchronous shutdown is generation-guarded:** `stopRecording`'s tail runs after `await transcribeUseCase.stop()` and a drain of up to 3 s, by which time the user may have started the next meeting. It re-checks `sessionEpoch` before touching session state; without that it closed the NEW session's request stream and timed out its phrases.
- **A session that fails still closes:** every path that ends a recording goes through a teardown (`teardownAfterFailure`) that finishes the request stream, stops the level poll, resolves the pending fragments and archives. The error paths used to just set `.idle`, leaving a stream with no consumer and a screen full of spinners that were indistinguishable from work in progress.
- **Logging:** All components use `OSLog` with subsystem `com.spanesso.TraslatorApp` and per-component categories (`AppleSFSpeech`, `AudioCapture`, `AudioSession`, `SpeechRepo`, `UseCase`, `Segmenter`, `Quality`, `ViewModel`, `UI`, `Container`, `Coordinator`).
- **Telemetry (008):** category `Telemetry`, one line per event as `[KIND] sid=A1B2 key=value …`. Prefixes are a published interface — renaming one breaks every saved log filter. Telemetry carries counts, durations and error codes, **never transcribed text**, and never blocks or throws.

  ```
  [SESSION_END] sid=A1B2 reason=error errDomain=kAFAssistantErrorDomain errCode=203 durMs=61240 restartIdx=7
  grep '\[TAP_SWAP\]'    | grep -v 'blindMs=0'      # must be EMPTY
  grep '\[STAB_CANCEL\]' | grep 'rescheduled=false' # must be EMPTY
  grep '\[RECOGNIZER_DEAF\]'                        # rotated=true → the recogniser stopped
                                                    # listening; consecutive climbing → the mic
  grep '\[TAP_STALL\]'                              # must be EMPTY: no buffers reached the tap
  grep '\[RESTART_END\]'                            # carryMs = audio actually replayed (measured)
  grep '\[RESOURCES\]'                              # thermal=serious|critical, availMB falling
  ```

  `TAP_FIRST_BUFFER` is emitted when the first buffer really arrives, and `AUDIO_CONFIG_CHANGE match=` compares the hardware format with the tap's — both used to be emitted with assumed values.

## TranslatorState

```swift
enum TranslatorState {
    case idle
    case inFlight           // translation request in flight
    case error              // generic ASR/audio error
    case permissionDenied   // microphone or speech recognition auth denied
    case modelUnavailable   // Apple Translation model not downloaded
    case downloadingModel
    case downloadingASRModel(progress: Double)
    case correcting
    case suspendedByAudioInterruption(AudioInterruptionReason)  // 008: recoverable pause
}
```

## Known Limitations

- **Language pair is hardcoded** (`en-US → es-ES`); no language picker exists.
- **UI tests** (`TranslatorAppUITests`) are scaffolding only. Real unit tests live in `TranslatorAppTests` (35 cases covering the reconciler, the formatter, session-state transitions and segmenter timing).
- **The WhisperKit engine is withdrawn** (008 decision Q1). `EnginePreference.whisperPreferred` is retained as a stored value but resolves to the Apple route; `isAvailable` returns false and the UI shows it as unavailable. `WhisperKitEngine.swift` stays in the repo, unreferenced, pending a redesign (sliding window with overlap, stable-segment emission).
- **`SpeechAnalyzer` is not used.** With a 26.1 deployment target it is available on every supported device and would remove session rotation entirely — making US6 and part of US2 unnecessary. Deliberately deferred; see `specs/008-fix-audio-pipeline-resilience/research.md` §R6.
- **First-time translation model download** is surfaced as an error banner; the user must open Settings manually.

## Active Technologies
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + SwiftUI · Speech (SFSpeechRecognizer) · AVFoundation · NaturalLanguage · Translation (Apple on-device) · SwiftData · OSLog (003-fix-save-export)
- SwiftData (macOS 14+) — in-memory + on-disk via `ModelContainer` (003-fix-save-export)
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency) (005-accent-robust-asr)
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency) + SwiftUI · Speech (`SFSpeechRecognizer`; iOS 26 `SpeechAnalyzer`/`SpeechTranscriber` in Phase 3) · AVFoundation (`AVAudioEngine`, `AVAudioConverter`) · NaturalLanguage (`NLTokenizer`/`NLTagger`) · Translation (Apple on-device) · WhisperKit (SPM, already present) · BackgroundAssets · OSLog · SwiftData (006-fix-asr-word-loss)
- SwiftData (`ConversationRecord`, `SessionQualityRecord`); WhisperKit model files on disk in App Support. No new file types. (006-fix-asr-word-loss)
- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (strict concurrency) + SwiftUI, Speech (`SFSpeechRecognizer`), AVFoundation, NaturalLanguage, Translation (Apple on-device), SwiftData, OSLog (007-preserve-conversation-history)
- In-memory per live session (`TranscriptionViewModel` arrays). Persistence of a finished session is existing SwiftData Save/Export — unchanged. (007-preserve-conversation-history)
- Swift 5.0 con `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` (concurrencia estricta) + SwiftUI · Speech (`SFSpeechRecognizer`) · AVFoundation (`AVAudioEngine`, `AVAudioSession`) · NaturalLanguage (`NLTokenizer`, `NLTagger`) · Translation (Apple, en dispositivo) · SwiftData · OSLog. **Sin dependencias nuevas.** WhisperKit permanece como paquete SPM pero queda sin referenciar por el selector de motor. (008-fix-audio-pipeline-resilience)
- SwiftData (`ConversationRecord`, `SessionQualityRecord`). **Sin migración de esquema** (decisión Q2). (008-fix-audio-pipeline-resilience)

- Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
- SwiftUI, Speech (SFSpeechRecognizer), AVFoundation, NaturalLanguage (NLTokenizer), Translation (Apple on-device), OSLog
- In-memory only (no persistence)

## Recent Changes
- 003-fix-save-export: Added Swift 5.0, `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` + SwiftUI · Speech (SFSpeechRecognizer) · AVFoundation · NaturalLanguage · Translation (Apple on-device) · SwiftData · OSLog
