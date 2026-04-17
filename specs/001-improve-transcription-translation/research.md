# Research: Improve Live Transcription & Translation Quality

**Feature**: `001-improve-transcription-translation`  
**Date**: 2026-04-17  
**Branch**: `001-improve-transcription-translation`

---

## Decision 1: Root Cause of Duplication in emittedPhrases

**Decision**: The primary duplication source is in `NLPSegmenterService.processStream()` — a single ASR update can trigger both the "sentence" path (NLTokenizer emits complete sentences) and then the "terminator" or "final" path on the recalculated tail, potentially emitting overlapping content. The `pendingSuffix()` diff is word-count based and breaks under ASR corrections that change token count without changing logical content.

**Rationale**: The code at lines 56-72 of `NLPSegmenterService.swift` first emits all-but-last sentences, then recalculates the tail via `pendingSuffix()`, and then checks again for terminators. If the recalculated tail contains words that were part of a sentence already emitted (due to an off-by-one in word counting), it will double-emit. Additionally, `currentBuffer = segment.text` in `TranscriptionViewModel` assigns the *full accumulated* ASR transcript (not just the new delta), which visually overlaps with `emittedPhrases` already displayed above it.

**Secondary source**: `appendTranslation()` only deduplicates against the *last* translated sentence. If a phrase is re-emitted after a gap, it passes the dedup guard.

**Alternatives considered**:
- Assume duplication is purely a UI rendering issue → rejected: the segmenter emits duplicate strings that can be confirmed via OSLog `Segmenter` category.
- Fix only at ViewModel level → insufficient: must fix at segmenter emit level to prevent unnecessary translation calls.

---

## Decision 2: How to Fix pendingSuffix Reliability

**Decision**: Replace word-count-based diffing in `pendingSuffix()` with string-prefix stripping. The committed text is stored as `committedFullText`. The pending suffix is simply `fullText` with `committedFullText` stripped from the start (after normalizing whitespace). This is O(n) and immune to word-count drift from ASR corrections.

**Rationale**: The current approach counts words in `committedFullText` and skips that many words in `fullText`. ASR corrections (e.g., "know" → "no", "it's" → "its") can change the word boundary indices without changing word count, causing `pendingSuffix()` to return an incorrect slice. String prefix comparison on normalized text is deterministic.

**Alternatives considered**:
- Character-offset tracking → more precise but harder to maintain across ASR revisions that insert/remove characters mid-string.
- Dedicated diff algorithm (LCS) → overkill for a monotonically growing transcript.

---

## Decision 3: Context-Aware Translation with Apple Translation Framework

**Decision**: Apple's `Translation` framework (iOS 17.4+ / macOS 14.4+) does not expose a system prompt or context parameter in its public API. The workaround is to prepend a compact context block to each translation request: `"[Context: <last N sentences>]\n\n<current sentence>"`. The translator sees the context as part of the input and produces a more coherent continuation. The translated context block must be stripped from the response output.

**Rationale**: The framework's `TranslationSession.translate(_:)` takes a single `String` argument. There is no structured context API. However, prepending context as natural-language text does influence translation quality for idioms and pronoun resolution, as the underlying neural MT model attends to the full input string. This technique is used by production simultaneous translation apps constrained to on-device engines.

**Context format**:
```
[Context: Previously: "We're restructuring the organization. The corporate events team led this."]

In a nutshell, this means fewer layers.
```

The response will contain only the translated target sentence (the model does not translate the `[Context: ...]` directive literally). Post-processing strips any leaked context prefix from the response.

**Configurable parameter**: `contextWindowSize: Int = 3` (number of prior sentences to prepend).

**Alternatives considered**:
- Use a local LLM (e.g., llama.cpp) for context-aware translation → introduces a heavy dependency (300MB+ model), rejected per spec constraints.
- Use a cloud API (DeepL, OpenAI) with system prompt → violates on-device requirement.
- No context at all → current state, produces idiom errors, rejected.

---

## Decision 4: currentBuffer Visual Overlap with emittedPhrases

**Decision**: `currentBuffer` in `TranscriptionViewModel` stores the full accumulated ASR transcript (`segment.text` is cumulative). The `englishPane()` displays both `emittedPhrases` (committed segments) and `currentBuffer` (live tail). The overlap occurs because `currentBuffer` contains text that is already in `emittedPhrases`.

**Fix**: After `NLPSegmenterService` emits a phrase, `TranscriptionViewModel` must update `currentBuffer` to show only the *uncommitted tail* — i.e., the portion of the last raw ASR result that has not yet been emitted. This requires `NLPSegmenterService` to expose its `committedFullText` length (or the tail substring directly), or for `TranscriptionViewModel` to track an `emittedCharacterCount` offset.

**Recommended approach**: Add a `currentTail: String` output to `NLPSegmenterService` (or derive it in the ViewModel) that represents `rawSegment.text` minus the already-committed prefix. The `currentBuffer` in the ViewModel is set to this tail, not the full transcript.

**Alternatives considered**:
- Hide `emittedPhrases` in the UI and only show `currentBuffer` → loses the committed sentence history view.
- Show only `emittedPhrases` and no live tail → acceptable fallback but loses the "streaming" feel the user asked for.

---

## Decision 5: Configurable Parameters and Their Defaults

| Parameter | Default | Rationale |
|-----------|---------|-----------|
| `stabilityDelay` | 700ms | Current value. Fires when ASR stabilizes without punctuation. 700ms is below natural inter-sentence pause (~1–2s) and avoids cutting mid-clause. |
| `longSentenceWordThreshold` | 15 words | Current value. ~3 seconds of average speech (5 words/s). Prevents unbounded buffers. |
| `contextWindowSize` | 3 sentences | Enough to resolve pronouns and idioms without making the translation request too long for on-device model. |
| `maxFlushDelay` | 5000ms | New parameter. If the user stops speaking and silence exceeds this, remaining buffer is flushed even if < minShortPhraseWords. |
| `minShortPhraseWords` | 2 words | Current value. Prevents single-word ghost translations (articles, conjunctions). |
| `requiresOnDeviceRecognition` | false | Keep default — macOS/iOS hybrid mode provides better accuracy. Flip to true for strict offline mode. |

---

## Decision 6: Translation Lifecycle — taskID Rotation Safety

**Decision**: The existing `taskID` rotation pattern in `TranscriptionViewModel` (new UUID assigned before `translationConfig`) is correct and must be preserved. The fix for duplicate translations should not alter this lifecycle.

**Rationale**: As documented in CLAUDE.md: assigning `translationConfig` without rotating `taskID` leaves a stale `.translationTask` subtree consuming the old `AsyncStream`. This ordering is a known, documented invariant.

---

## Decision 7: Files to Modify

| File | Changes Needed |
|------|---------------|
| `NLPSegmenterService.swift` | Fix `pendingSuffix()` to use string-prefix stripping; expose committed prefix length or tail string; add `maxFlushDelay` parameter |
| `TranscriptionViewModel.swift` | Update `currentBuffer` to show only uncommitted tail; strengthen `appendTranslation` dedup (full array scan, not just last); add context window tracking |
| `LiveTranscriptionView.swift` | Pass context window sentences to translation request (via context injection); minor: no structural changes required |
| `TranscribeAudioUseCase.swift` | No changes needed |
| `ContinuousSpeechListener.swift` | Optional: set `requiresOnDeviceRecognition` configurable; no critical changes |
| New: `TranslationContextWindow.swift` | New actor/struct to accumulate (original, translated) sentence pairs and produce context string |

---

## Decision 8: No New External Dependencies

**Decision**: All changes use existing frameworks. No new Swift Package dependencies are introduced.

**Rationale**: The project currently has zero external package dependencies (no Package.swift, no .xcworkspace with SPM packages). Adding SPM packages for this scope is unjustified — all required capabilities (string manipulation, NLP tokenization, async/await concurrency, on-device translation) are already available in the SDK.
