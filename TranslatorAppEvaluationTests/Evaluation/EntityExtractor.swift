//
//  EntityExtractor.swift
//  TranslatorAppEvaluationTests
//
//  Lightweight proxy for named-entity detection used by the anti-hallucination
//  gate (SC-007). Uses a heuristic: capitalised non-first words are treated as
//  named entities (proper nouns). NLTagger is used where available as a more
//  accurate fallback, but the capitalisation heuristic is the gate arbiter
//  because it mirrors what FoundationModelsCorrector already checks.
//

import Foundation
import NaturalLanguage

struct EntityExtractor: Sendable {

    // MARK: - Public API

    /// Returns all probable named entities (proper nouns / names) in `text`.
    static func entities(in text: String) -> Set<String> {
        var result = Set<String>()
        result.formUnion(capitalizedEntities(in: text))
        result.formUnion(nlTaggerEntities(in: text))
        return result
    }

    /// Returns entities present in `hypothesis` that are NOT in `reference`.
    /// These are "hallucinated" entities — the corrector should have rejected them.
    static func hallucinatedEntities(reference: String, hypothesis: String) -> Set<String> {
        let refEntities = entities(in: reference)
        let hypEntities = entities(in: hypothesis)
        return hypEntities.subtracting(refEntities)
    }

    // MARK: - Heuristic: capitalised non-first words

    private static func capitalizedEntities(in text: String) -> Set<String> {
        var result = Set<String>()
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
        for sentence in sentences {
            let words = sentence.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            for (idx, word) in words.enumerated() {
                guard idx > 0 else { continue }
                let stripped = word.trimmingCharacters(in: .punctuationCharacters)
                if let first = stripped.first, first.isUppercase, stripped.count > 1 {
                    result.insert(stripped.lowercased())
                }
            }
        }
        return result
    }

    // MARK: - NLTagger (iOS 14+, supplementary signal)

    private static func nlTaggerEntities(in text: String) -> Set<String> {
        var result = Set<String>()
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        let range = text.startIndex..<text.endIndex
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
        tagger.enumerateTags(in: range, unit: .word, scheme: .nameType, options: options) { tag, tokenRange in
            if tag == .personalName || tag == .organizationName || tag == .placeName {
                result.insert(String(text[tokenRange]).lowercased())
            }
            return true
        }
        return result
    }

    // MARK: - Numeral extraction (SC-007 invariant: no introduced numerals)

    private static let numeralPattern = try! NSRegularExpression(pattern: #"\b\d+([.,]\d+)?\b"#)

    static func numerals(in text: String) -> Set<String> {
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return Set(numeralPattern.matches(in: text, range: range).map { ns.substring(with: $0.range) })
    }

    static func hallucinatedNumerals(reference: String, hypothesis: String) -> Set<String> {
        numerals(in: hypothesis).subtracting(numerals(in: reference))
    }
}
