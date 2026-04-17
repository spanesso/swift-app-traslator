# Async Stream Contracts

**Feature**: `001-improve-transcription-translation`  
**Date**: 2026-04-17

These contracts define the expected behavior of `AsyncStream` channels between layers. They are internal contracts, not public APIs.

---

## Contract 1: SpeechRepository → TranscribeAudioUseCase

```
Stream type: AsyncStream<SpeechSegment>
Producer: ContinuousSpeechListener (actor)
Consumer: TranscribeAudioUseCase.executeBoth() fan-out pump

Guarantees:
  - Elements are ordered by ASR result timestamp
  - Each element's .text field is the FULL accumulated transcript so far (not a delta)
  - .isFinal = true on the last element of an utterance; false for all partials
  - Stream finishes (no more elements) when recording is stopped
  - Stream never yields after finishing

Error behavior:
  - ASR errors surface via SpeechError thrown before the stream starts; the stream itself does not throw
```

---

## Contract 2: TranscribeAudioUseCase fan-out → NLPSegmenterService

```
Stream type: AsyncStream<SpeechSegment>
Producer: detached pump Task in executeBoth()
Consumer: NLPSegmenterService.processStream()

Guarantees:
  - Same as Contract 1 (fan-out copy, same semantics)
  - Both rawOutput and segmentedInput receive the SAME element values
  - Fan-out does not buffer; back-pressure is handled by consumer Task scheduling

Invariant:
  - rawOutput and segmentedInput are consumed concurrently by separate Tasks
  - Neither consumer blocks the other
```

---

## Contract 3: NLPSegmenterService → TranscriptionViewModel (stable phrases)

```
Stream type: AsyncStream<String>
Producer: NLPSegmenterService.processStream()
Consumer: TranscriptionViewModel.startRecording() stableStream loop

Guarantees (NEW/CHANGED from current implementation):
  - Each emitted String is a non-empty, non-whitespace phrase of ≥ 2 words (after trim)
  - Each emitted String is a STRICT DELTA — it does not overlap with any previously emitted string
  - No two emitted strings in the same session are identical
  - Strings are emitted in the order they were spoken (monotonically advancing in the transcript)
  - Stream finishes when the source SpeechSegment stream finishes and all buffered content is flushed

Invariant (NEW):
  - concat(all emitted strings, separator: " ") ≈ the full session transcript
    (modulo stopwords filtered at minShortPhraseWords threshold)
```

---

## Contract 4: TranscriptionViewModel → LiveTranscriptionView (translation requests)

```
Stream type: AsyncStream<String>
Producer: TranscriptionViewModel (translationContinuation.yield)
Consumer: LiveTranscriptionView .translationTask modifier

Guarantees:
  - Each yielded string is a translation request in the format:
      "[Context: <contextString>]\n\n<sentence>"  — when prior context exists
      "<sentence>"                                 — for the first sentence
  - The translation engine must strip any "[Context: ...]" prefix from its response
    before calling viewModel.appendTranslation()
  - Stream lifetime matches the recording session (rotated on each record/stop cycle via taskID)
```

---

## Contract 5: LiveTranscriptionView → TranscriptionViewModel (translation results)

```
Call: viewModel.appendTranslation(_ translation: String, originalSentence: String)
Caller: LiveTranscriptionView .translationTask modifier (after stripping context prefix)
Callee: TranscriptionViewModel (@MainActor)

NEW SIGNATURE: appendTranslation now takes originalSentence parameter
  - Needed so TranslationContextWindow can store (original, translated) pairs

Guarantees:
  - Called at most once per translation request
  - translation is the translated target-language text only (no context prefix leaked)
  - originalSentence matches the sentence that was yielded in Contract 4
```

---

## Contract 6: TranscriptionViewModel → englishPane (currentBuffer)

```
Property: viewModel.currentBuffer: String
Type: @Observable binding

Semantics (CHANGED from current):
  - currentBuffer = full_raw_transcript.dropPrefix(committedText)
  - i.e., only the words NOT yet in emittedPhrases
  - Empty string when all spoken text has been committed

Why this matters:
  - Previously: currentBuffer = full transcript → visually repeated emittedPhrases content
  - After fix: currentBuffer = only the live uncommitted tail → no visual overlap
```
