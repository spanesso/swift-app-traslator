//
//  WERCalculator.swift
//  TranslatorAppEvaluationTests
//
//  Levenshtein-based WER and CER. Standard edit-distance algorithm; no
//  external dependencies. Normalises case and strips punctuation before
//  comparison so minor ASR formatting differences don't inflate the error.
//

import Foundation

struct WERCalculator: Sendable {

    // MARK: - Word Error Rate

    /// WER = (S + D + I) / N  where N = reference word count
    static func wer(reference: String, hypothesis: String) -> Double {
        let ref = tokenize(reference)
        let hyp = tokenize(hypothesis)
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        let edits = editDistance(ref, hyp)
        return Double(edits) / Double(ref.count)
    }

    // MARK: - Character Error Rate

    /// CER = edit distance on characters / reference char count
    static func cer(reference: String, hypothesis: String) -> Double {
        let ref = Array(normalise(reference))
        let hyp = Array(normalise(hypothesis))
        guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
        let edits = editDistance(ref.map(String.init), hyp.map(String.init))
        return Double(edits) / Double(ref.count)
    }

    // MARK: - Batch aggregation (macro-average)

    struct BatchResult: Sendable {
        let wer: Double
        let cer: Double
        let itemCount: Int
    }

    static func batch(_ pairs: [(reference: String, hypothesis: String)]) -> BatchResult {
        guard !pairs.isEmpty else { return BatchResult(wer: 0, cer: 0, itemCount: 0) }
        let werSum = pairs.reduce(0.0) { $0 + wer(reference: $1.reference, hypothesis: $1.hypothesis) }
        let cerSum = pairs.reduce(0.0) { $0 + cer(reference: $1.reference, hypothesis: $1.hypothesis) }
        return BatchResult(wer: werSum / Double(pairs.count),
                           cer: cerSum / Double(pairs.count),
                           itemCount: pairs.count)
    }

    // MARK: - Private

    private static func tokenize(_ text: String) -> [String] {
        normalise(text).components(separatedBy: .whitespaces).filter { !$0.isEmpty }
    }

    private static func normalise(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.punctuationCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Standard Levenshtein on string arrays (tokens or characters).
    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        let m = a.count, n = b.count
        if m == 0 { return n }
        if n == 0 { return m }
        var dp = Array(repeating: Array(repeating: 0, count: n + 1), count: m + 1)
        for i in 0...m { dp[i][0] = i }
        for j in 0...n { dp[0][j] = j }
        for i in 1...m {
            for j in 1...n {
                dp[i][j] = a[i - 1] == b[j - 1]
                    ? dp[i - 1][j - 1]
                    : 1 + min(dp[i - 1][j], dp[i][j - 1], dp[i - 1][j - 1])
            }
        }
        return dp[m][n]
    }
}
