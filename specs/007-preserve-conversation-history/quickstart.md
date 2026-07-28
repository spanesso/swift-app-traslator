# Quickstart: Preserve Full Conversation History

Goal: verify that a live session retains its entire transcript/translation, that auto-follow
and existing behaviors are intact, and that long sessions stay responsive.

## Build

```bash
open TranslatorApp.xcodeproj    # then ⌘R on an iPhone target
# or headless build check:
xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp \
  -destination 'generic/platform=iOS' build
```

## Manual verification (device or simulator with audio input)

### T-A. Full history retained (US1 / FR-001–FR-004 / SC-001)
1. Start recording.
2. Feed enough distinct speech to produce **more than 50 EN phrases and 30 ES sentences**
   (the old caps) — e.g., play a several-minute talk, or read continuously for a few minutes.
3. Scroll to the **top** of the ORIGINAL (EN) pane → the very first phrase of the session is
   still present.
4. Scroll to the **top** of the TRANSLATION (ES) pane → the first translated sentence is still
   present, in order.
5. ✅ Pass if nothing from the start of the session is missing.

### T-B. Auto-follow not regressed (US2 / FR-008 / SC-004)
1. While still recording and scrolled to the bottom, keep speaking.
2. The newest EN phrase and ES sentence stay in view at the bottom.
3. Scroll up to read old content, then scroll back down → history above is intact and the live
   line resumes following.
4. ✅ Pass if auto-follow behaves as before and no content vanished.

### T-C. Restart continuity (FR-005)
1. Mid-session, tap the orange **Restart Listening** button.
2. Previously captured phrases/sentences remain; new speech appends after them.
3. ✅ Pass if history is preserved across the restart.

### T-D. New session resets intentionally (FR-006)
1. Stop recording, then start a **new** recording.
2. Panes clear to "Waiting for audio…".
3. ✅ Pass — this reset is expected; the prior session is retained only if it was Saved/Exported.

### T-E. Save / Export completeness (FR-007 / SC-003)
1. After a long session (T-A), stop recording.
2. Tap **Save**, then **Export**.
3. Open the exported `.txt` → the ENGLISH TRANSCRIPT and SPANISH TRANSLATION sections contain
   the **entire** session, including the earliest phrases.
4. ✅ Pass if counts match what was captured (no shortfall from trimming).

### T-F. Long-session responsiveness (FR-009 / SC-005)
1. Run a 20–30 min continuous session.
2. Scroll from newest content all the way to the first phrase and back.
3. ✅ Pass if scrolling stays smooth and live updates do not stutter.

## Regression checklist (must remain green)
- Duplicate suppression: no repeated EN phrase / contained ES sentence appears.
- Confidence styling: low-confidence lines still render dimmer.
- Translation model download/unavailable banners still work.
- No new Swift 6 / strict-concurrency warnings introduced.
