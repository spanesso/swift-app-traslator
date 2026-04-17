//
//  TranslationContextWindow.swift
//  TranslatorApp
//

import Foundation

/// Tracks the last N (original, translated) sentence pairs to provide
/// context for subsequent translation requests, improving idiom and
/// pronoun resolution.
struct TranslationContextWindow {
    var windowSize: Int = 3  // default: 3 prior sentences
    private var pairs: [(original: String, translated: String)] = []

    mutating func append(original: String, translated: String) {
        pairs.append((original, translated))
        if pairs.count > windowSize {
            pairs.removeFirst()
        }
    }

    /// Compact context string for prepending to a translation request.
    /// Returns empty string when no prior pairs exist.
    func contextString() -> String {
        guard !pairs.isEmpty else { return "" }
        return pairs.map { "\"\($0.original)\" → \"\($0.translated)\"" }
            .joined(separator: ". ")
    }

    /// Full translation request string: context block + sentence.
    /// When context exists, prepends "[Context: <ctx>]\n\n<sentence>".
    func requestText(for sentence: String) -> String {
        let ctx = contextString()
        guard !ctx.isEmpty else { return sentence }
        return "[Context: Previously: \(ctx)]\n\n\(sentence)"
    }
}
