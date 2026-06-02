# Quickstart: Fix Translation Pipeline

**Branch**: `002-fix-translation-pipeline`

## What this feature fixes

The transcription → segmentation → translation pipeline has several interconnected bugs that cause translation to silently stall or never start. This guide covers how to verify the fix is working after implementation.

---

## Build

```bash
open TranslatorApp.xcodeproj
# Then ⌘B to build
```

**Expected**: Zero errors, zero warnings (including Swift concurrency warnings — `SWIFT_TREAT_WARNINGS_AS_ERRORS` is off, but any Swift 6 concurrency warning is a sign a fix was incomplete).

---

## Manual Test Protocol

### Test 1 — Baseline Translation (P1)

1. Launch app
2. Grant microphone + speech recognition permissions when prompted
3. Tap **Record**
4. Speak clearly: *"Hello, my name is Alex and I am testing the translation pipeline."*
5. Pause for 1 second
6. **Expected**: Left pane shows English text updating. Right pane shows Spanish translation within 3 s of your pause.
7. Tap **Stop**

**Pass**: Both panes updated. Translation appeared. Stop did not freeze.

---

### Test 2 — Stop and Restart (P1)

After Test 1:
1. Tap **Record** again
2. Speak: *"This is a second test session."*
3. **Expected**: Both panes are CLEARED from previous session. New text appears fresh.
4. Tap **Stop**
5. Repeat once more (third session)

**Pass**: Three consecutive sessions work without requiring app restart.

---

### Test 3 — No Duplicate Phrases (P2)

1. Tap **Record**
2. Speak five distinct sentences with natural pauses:
   - *"The weather is nice today."*
   - *"I enjoy programming in Swift."*
   - *"Translation is an important feature."*
   - *"Quality metrics help us improve."*
   - *"Thank you for using this app."*
3. Tap **Stop**

**Pass**: Spanish pane shows exactly five distinct entries. No sentence repeated. No sentence missing.

---

### Test 4 — Permission Error (P2)

1. In macOS System Settings → Privacy & Security → Microphone → disable TranslatorApp
2. Launch app and tap Record
3. **Expected**: An error alert appears immediately. Record button returns to idle state. App does not freeze.

**Pass**: Error is descriptive (mentions microphone permission). App recoverable without restart.

---

## Log Inspection

View structured logs in **Console.app** or Xcode console. Filter by subsystem `com.spanesso.TraslatorApp`.

Key log events to verify correct pipeline:

| Log Pattern | What it means |
|-------------|---------------|
| `[ASR-PARTIAL]` | ASR update received |
| `[BUFFER-FLUSH reason=sentence]` | NLP emitted a complete sentence |
| `[BUFFER-FLUSH reason=silence]` | Stability timer triggered a flush |
| `[BUFFER-FLUSH reason=flush]` | End-of-session trailing text flushed |
| `[TRANSLATE-START id=N]` | Phrase sent to Apple Translation |
| `[TRANSLATE-DONE id=N ms=X]` | Translation returned |
| `[COMMIT id=N]` | Translation appended to buffer |

**Red flags** (should not appear):
- `[TRANSLATE-START]` with no subsequent `[TRANSLATE-DONE]` — translation hung
- Absence of `[BUFFER-FLUSH]` despite speaking — segmenter not receiving segments
- Duplicate `[COMMIT]` entries with identical text

---

## What Changed (Implementation Summary)

| File | Change |
|------|--------|
| `ContinuousSpeechListener.swift` | `stop()` now calls `continuation?.finish()` before setting `continuation = nil` |
| `NLPSegmenterService.swift` | Converted to `actor`; merge conflict resolved (HEAD version kept); `isLowQualitySpeech()` wired to adaptive stability timer |
| `TranscribeAudioUseCase.swift` | Merge conflict resolved; `executeBoth()` kept; pump Task stored for explicit cancellation |
| `TranscriptionViewModel.swift` | Merge conflict resolved; `startRecording()` uses `executeBoth()`; `stopRecording()` cancels in correct order |
| `LiveTranscriptionView.swift` | Merge conflict resolved; `taskID` rotation kept; richer EN/ES panes from HEAD kept |
| `TranslatorState.swift` | Added `.permissionDenied` and `.modelUnavailable` cases |
| `TranslatorAppApp.swift` | ViewModel cached in `@State` instead of constructed on every `body` call |
| `DependencyContainer.swift` | Merge conflict resolved (minor) |
