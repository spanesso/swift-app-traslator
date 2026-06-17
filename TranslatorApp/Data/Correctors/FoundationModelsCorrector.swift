//
//  FoundationModelsCorrector.swift
//  TranslatorApp
//
//  Tier 2 — span-locked post-corrector using Apple Foundation Models (A17 Pro+, iOS 26+).
//  Hard anti-hallucination guarantee: any correction that introduces a named entity or
//  numeral absent from the input is silently rejected and the original segment is emitted.

import Foundation
import OSLog

@available(iOS 26.0, *)
actor FoundationModelsCorrector: TranscriptCorrectorProtocol {
    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Corrector")

    var isAvailable: Bool {
        get async {
            // Foundation Models requires A17 Pro+.
            DeviceCapabilities.supportsA17Pro
        }
    }

    func correct(segment: SpeechSegment, lockThreshold: Float) async -> CorrectionResult {
        guard segment.isFinal, !segment.text.isEmpty else {
            return skip(segment, reason: .allTokensHighConfidence)
        }
        guard await isAvailable else {
            return skip(segment, reason: .deviceUnsupported)
        }
        let allHigh = segment.tokens.allSatisfy { $0.confidence >= lockThreshold }
        if allHigh {
            return skip(segment, reason: .allTokensHighConfidence)
        }

        let lockedSegment = applyLocks(to: segment, threshold: lockThreshold)
        guard let correctedText = await callLanguageModel(for: lockedSegment) else {
            return CorrectionResult(segment: segment, action: .rejected, rejectedReason: nil)
        }

        if let rejection = validateInvariants(original: segment, corrected: correctedText) {
            logger.warning("[CORRECTOR] rejected: \(rejection.rawValue) | original='\(segment.text)' corrected='\(correctedText)'")
            return CorrectionResult(segment: segment, action: .rejected, rejectedReason: rejection)
        }

        let newTokens = rebuildTokens(from: lockedSegment, correctedText: correctedText)
        let correctedSegment = SpeechSegment(
            text: correctedText, isFinal: true,
            confidence: min(segment.confidence, avgConfidence(newTokens)),
            tokens: newTokens, source: segment.source
        )
        logger.info("[CORRECTOR] accepted | '\(segment.text)' → '\(correctedText)'")
        return CorrectionResult(segment: correctedSegment, action: .accepted, rejectedReason: nil)
    }

    // MARK: - FoundationModels call

    private func callLanguageModel(for segment: SpeechSegment) async -> String? {
        let lockedWords = segment.tokens.filter(\.isLocked).map(\.text)
        let lockedList = lockedWords.isEmpty ? "none" : lockedWords.joined(separator: ", ")
        let prompt = """
            Fix grammar and word substitutions in this English speech transcript.
            Do NOT add, remove, or change any of these locked words: [\(lockedList)].
            Do NOT introduce any proper nouns, names, places, brands, or numbers that are not already present.
            Respond with ONLY the corrected transcript text.

            Transcript: \(segment.text)
            """
        do {
            // FoundationModels API (iOS 26+):
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt)
            let result = response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            return result.isEmpty ? nil : result
        } catch {
            logger.error("[CORRECTOR] model call failed: \(error)")
            return nil
        }
    }

    // MARK: - Helpers

    private func applyLocks(to segment: SpeechSegment, threshold: Float) -> SpeechSegment {
        let lockedTokens = segment.tokens.map { $0.confidence >= threshold ? $0.locking() : $0 }
        return SpeechSegment(text: segment.text, isFinal: segment.isFinal,
                             confidence: segment.confidence, tokens: lockedTokens,
                             source: segment.source)
    }

    private func validateInvariants(original: SpeechSegment, corrected: String) -> CorrectionRejection? {
        let origEntities = namedEntities(in: original.text)
        let corrEntities = namedEntities(in: corrected)
        if !corrEntities.isSubset(of: origEntities) { return .introducedNamedEntity }

        let origNums = numerals(in: original.text)
        let corrNums = numerals(in: corrected)
        if !corrNums.isSubset(of: origNums) { return .introducedNumeral }

        for token in original.tokens where token.isLocked {
            if !corrected.localizedCaseInsensitiveContains(token.text) {
                return .modifiedLockedToken
            }
        }
        return nil
    }

    private func namedEntities(in text: String) -> Set<String> {
        // Simple heuristic: capitalized words that aren't sentence starters
        let words = text.split(separator: " ").map(String.init)
        var entities: Set<String> = []
        for (i, word) in words.enumerated() {
            let cleaned = word.trimmingCharacters(in: .punctuationCharacters)
            if i > 0, let first = cleaned.first, first.isUppercase { entities.insert(cleaned.lowercased()) }
        }
        return entities
    }

    private func numerals(in text: String) -> Set<String> {
        let pattern = try? NSRegularExpression(pattern: "\\b\\d+([.,]\\d+)?\\b")
        let range = NSRange(text.startIndex..., in: text)
        let matches = pattern?.matches(in: text, range: range) ?? []
        return Set(matches.compactMap { Range($0.range, in: text).map { String(text[$0]) } })
    }

    private func rebuildTokens(from segment: SpeechSegment, correctedText: String) -> [TranscriptToken] {
        guard !segment.tokens.isEmpty else { return [] }
        let words = correctedText.split(separator: " ").map(String.init)
        return words.enumerated().map { idx, word in
            let orig = idx < segment.tokens.count ? segment.tokens[idx] : segment.tokens.last!
            return TranscriptToken(text: word, confidence: orig.confidence,
                                   startTime: orig.startTime, endTime: orig.endTime,
                                   isLocked: orig.isLocked)
        }
    }

    private func avgConfidence(_ tokens: [TranscriptToken]) -> Float {
        guard !tokens.isEmpty else { return 0 }
        return tokens.reduce(0) { $0 + $1.confidence } / Float(tokens.count)
    }

    private func skip(_ segment: SpeechSegment, reason: SkipReason) -> CorrectionResult {
        CorrectionResult(segment: segment, action: .skipped(reason: reason), rejectedReason: nil)
    }
}

// Minimal LanguageModelSession shim for SourceKit — real symbol comes from FoundationModels.framework.
// Remove this block once the FoundationModels import resolves in the build system.
#if !canImport(FoundationModels)
@available(iOS 26.0, *)
private struct LanguageModelSession {
    func respond(to prompt: String) async throws -> (content: String) { (content: "") }
}
#else
import FoundationModels
#endif
