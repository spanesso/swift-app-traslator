# Data Model: Improve Live Transcription & Translation Quality

**Feature**: `001-improve-transcription-translation`  
**Date**: 2026-04-17

---

## Existing Entities (Modified)

### SpeechSegment *(no changes)*
```
SpeechSegment
  text: String          — full accumulated ASR transcript (cumulative)
  isFinal: Bool         — true when ASR closes the utterance
  confidence: Float     — ASR confidence score [0.0–1.0]
```

### NLPSegmenterService *(internal state changes)*

Current state:
```
committedFullText: String     — full text that has been emitted for translation
lastSeenFullText: String      — last observed ASR transcript
```

New state (additions):
```
committedCharCount: Int       — character count of committedFullText after normalization
                                (used by pendingSuffix to compute tail via string prefix strip)
maxFlushDelay: TimeInterval   — configurable, default 5.0s
                                (new: flush remaining buffer if silence exceeds this)
```

Emit contract changes:
- `pendingSuffix(of:)` now returns `fullText` with committed prefix stripped (string-based, not word-count-based)
- Emitted strings are guaranteed non-overlapping with all prior emitted strings

### TranscriptionViewModel *(extended)*

Current state:
```
currentBuffer: String                — previously: full ASR transcript (WRONG)
translatedBuffer: String             — joined translations
translatedSentences: [String]        — max 30
emittedPhrases: [String]             — max 50
translationRequests: AsyncStream<String>
```

New/changed state:
```
currentBuffer: String                — CHANGED: now holds only the uncommitted tail
                                       (text not yet emitted as a stable segment)
translationContext: TranslationContextWindow  — NEW: tracks last N (original, translated) pairs
emittedPhraseSet: Set<String>        — NEW: O(1) duplicate detection for emittedPhrases
```

---

## New Entities

### TranslationContextWindow *(new file)*

```
TranslationContextWindow
  windowSize: Int                    — configurable, default 3
  pairs: [(original: String, translated: String)]
                                     — ring buffer of last N sentence pairs
  
  Methods:
  - append(original: String, translated: String) → Void
      Add a new pair; drops oldest when windowSize exceeded
  - contextString() → String
      Returns compact context block for prepending to translation request:
      "Previously: \"<s1>\" → \"<t1>\". \"<s2>\" → \"<t2>\"."
      Returns empty string if no prior pairs exist
  - requestText(for sentence: String) → String
      Returns full translation request string:
      "[Context: <contextString>]\n\n<sentence>"  if context non-empty
      "<sentence>"                                 if no context yet
```

**Ownership**: Owned by `TranscriptionViewModel`. Populated in `appendTranslation(_:originalSentence:)`.

**Thread safety**: Called from `@MainActor` context only. No actor isolation needed.

---

## State Transitions

### Session Lifecycle

```
IDLE
  │ startRecording()
  ▼
RECORDING
  │ ASR partial result arrives
  ▼ currentBuffer = tail (uncommitted portion only)
RECORDING
  │ NLPSegmenter emits stable phrase
  ▼ emittedPhrases.append(phrase)
  ▼ currentBuffer = new tail (phrase stripped from front)
  ▼ translationRequests.yield(phrase)
TRANSLATING (inFlight)
  │ Apple Translation responds
  ▼ appendTranslation(result, originalSentence: phrase)
  ▼ translationContext.append(original: phrase, translated: result)
  ▼ translatedSentences.append(result)
RECORDING (back to normal)
  │ stopRecording()
  ▼ buffer flush (any remaining tail → translation)
  ▼ translationRequests stream finishes
IDLE
```

### Deduplication Guards

1. **Segmenter level**: `pendingSuffix()` string-prefix stripping ensures emitted text never overlaps with already-committed text.
2. **ViewModel emittedPhrases level**: `emittedPhraseSet` O(1) lookup before appending to `emittedPhrases`.
3. **ViewModel translation level**: Full `translatedSentences` array scan (not just last item) for exact-match and containment dedup.

---

## Key Invariants

- `committedFullText` is always a prefix of the last-seen `segment.text` (after normalization).
- `currentBuffer` displayed in the UI is always equal to `lastRawSegmentText.dropPrefix(committedFullText)`.
- `emittedPhrases` and `translatedSentences` grow monotonically within a session; they are never modified or replaced, only appended.
- `translationContext.pairs` is bounded by `windowSize` — memory is O(windowSize × avgSentenceLength), not O(session length).
