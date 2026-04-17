# Developer Quickstart: Improve Live Transcription & Translation Quality

**Feature**: `001-improve-transcription-translation`  
**Date**: 2026-04-17

---

## What This Feature Fixes

Three compounding problems cause the current fragmented/incoherent translation experience:

| # | Problem | Root Cause | Fix Location |
|---|---------|------------|--------------|
| 1 | Duplicate text in original column | `currentBuffer` shows full transcript; `emittedPhrases` already shows committed portions | `TranscriptionViewModel` — compute tail only |
| 2 | Sentences cut mid-phrase | `pendingSuffix()` word-count diff drifts under ASR corrections | `NLPSegmenterService` — string-prefix diff |
| 3 | Idiom/context failures | Apple Translation gets isolated fragments with no prior context | New `TranslationContextWindow` + context injection in `.translationTask` |

---

## Files Changed

### 1. `NLPSegmenterService.swift` (Domain/Services)

**What changes**: `pendingSuffix(of:)` is replaced with a string-prefix stripping implementation. A `maxFlushDelay` parameter is added. The service exposes `committedPrefix: String` so `TranscriptionViewModel` can compute the display tail.

**Key change**:
```swift
// BEFORE (word-count based — drifts under ASR corrections):
private func pendingSuffix(of fullText: String) -> String {
    let allWords = fullText.split(separator: " ")
    let committedWords = committedFullText.split(separator: " ").count
    return allWords.dropFirst(committedWords).joined(separator: " ")
}

// AFTER (string-prefix based — deterministic):
private func pendingSuffix(of fullText: String) -> String {
    let normalized = fullText.trimmingCharacters(in: .whitespaces)
    let committed = committedFullText.trimmingCharacters(in: .whitespaces)
    guard normalized.hasPrefix(committed) else { return normalized }
    return String(normalized.dropFirst(committed.count))
        .trimmingCharacters(in: .whitespaces)
}
```

**New parameter**:
```swift
var maxFlushDelay: TimeInterval = 5.0  // flush remaining buffer after this silence
```

**New property exposed** (for ViewModel tail computation):
```swift
private(set) var committedFullText: String  // already exists; make accessible
```

---

### 2. `TranslationContextWindow.swift` (Domain/Services — NEW FILE)

**What this is**: A lightweight struct tracking the last N (original, translated) sentence pairs. Used to inject context into translation requests.

```swift
struct TranslationContextWindow {
    var windowSize: Int = 3
    private var pairs: [(original: String, translated: String)] = []

    mutating func append(original: String, translated: String) { ... }
    func contextString() -> String { ... }   // compact context for prepending
    func requestText(for sentence: String) -> String { ... }  // full request string
}
```

---

### 3. `TranscriptionViewModel.swift` (Presentation/ViewModels)

**What changes**:

a. `currentBuffer` is now set to the uncommitted tail, not the full transcript:
```swift
// In the raw stream consumer Task:
let tail = rawSegment.text.dropPrefix(nlpSegmenter.committedFullText)
await MainActor.run { self.currentBuffer = tail }
```

b. `appendTranslation` gains `originalSentence` parameter and uses full-array dedup:
```swift
func appendTranslation(_ translation: String, originalSentence: String) {
    let trimmed = translation.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    guard !translatedSentences.contains(where: { $0 == trimmed || trimmed.contains($0) }) else { return }
    translationContext.append(original: originalSentence, translated: trimmed)
    translatedSentences.append(trimmed)
    translatedBuffer = translatedSentences.joined(separator: "\n\n")
}
```

c. `translationContext: TranslationContextWindow` is added as a property.

d. `emittedPhraseSet: Set<String>` is added for O(1) dedup before appending to `emittedPhrases`.

---

### 4. `LiveTranscriptionView.swift` (Presentation/Views)

**What changes**: The `.translationTask` modifier injects context and strips it from the response.

```swift
.translationTask(translationConfig, id: taskID) { session in
    guard let stream = viewModel.translationRequests else { return }
    for await requestText in stream {
        // Extract the actual sentence (after the context block)
        let sentence = requestText.components(separatedBy: "\n\n").last ?? requestText
        let response = try await session.translate(requestText)
        // Strip any leaked "[Context: ...]" prefix from response
        let translated = response.targetText
            .replacingOccurrences(of: #"^\[Context:.*?\]\n\n?"#, with: "",
                                  options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        viewModel.appendTranslation(translated, originalSentence: sentence)
    }
}
```

No structural layout changes required.

---

## Configurable Parameters (with defaults)

| Parameter | Location | Default | How to tune |
|-----------|----------|---------|-------------|
| `stabilityDelay` | `NLPSegmenterService` | 700ms | Lower for faster flush; raise for fewer mid-clause cuts |
| `longSentenceWordThreshold` | `NLPSegmenterService` | 15 words | Lower for shorter segments; raise for longer natural sentences |
| `maxFlushDelay` | `NLPSegmenterService` | 5000ms | How long to hold a partial buffer after the user stops speaking |
| `minShortPhraseWords` | `NLPSegmenterService` | 2 words | Minimum to avoid single-word ghost translations |
| `contextWindowSize` | `TranslationContextWindow` | 3 sentences | More = better idiom/pronoun resolution; less = shorter requests |

All parameters are set at initialization in `DependencyContainer`. No runtime UI controls required.

---

## Manual Test Cases

### TC-1: Short sentence with idiom
**Input**: "In a nutshell, we restructured the team."  
**Expected**:  
- Original: shows "In a nutshell, we restructured the team." as a single committed phrase  
- Translation: "En pocas palabras, reestructuramos el equipo." (not "En la nueza")  
- No duplication in either column

### TC-2: Long sentence with no punctuation, natural pause
**Input**: Speak "The corporate events team led by Sarah handled logistics and vendor contracts and travel arrangements" without pausing  
**Expected**: Flush fires at clause marker (≤20 words) or at silence ≥ 700ms; translation covers a complete clause, "corporate events" is not cut

### TC-3: Pronoun reference across sentences
**Input**: "Sarah presented the report. It was excellent."  
**Expected**: "It" in the second sentence translates as "Fue excelente" (not "Lo fue" or "Ello fue"), because prior context names the report

### TC-4: Interruption / stop mid-sentence
**Input**: Start saying "We are planning to—" then tap Stop  
**Expected**: The partial buffer "We are planning to" (≥2 words) is flushed and translated; the app does not freeze or leave buffered text undisplayed

### TC-5: 5-minute continuous session
**Input**: Speak continuously for 5 minutes covering multiple topics  
**Expected**: Zero duplicate lines in original column; translation column only grows (no rewrites); app does not degrade in frame rate or responsiveness

---

## Build & Test

```bash
# Build
xcodebuild -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS' build

# Run UI tests (scaffolding only — use manual TC-1..TC-5 above for real validation)
xcodebuild test -project TranslatorApp.xcodeproj -scheme TranslatorApp -destination 'platform=macOS'
```
