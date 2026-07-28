//
//  ConversationTextFormatter.swift
//  TranslatorApp
//
//  The only producer of conversation text in the app
//  (008-fix-audio-pipeline-resilience, US7).
//
//  WHAT THIS REPLACES
//  Two duplicated formatters — one in the ViewModel for the live session, one in the detail view
//  for saved conversations — that joined the two languages with DIFFERENT separators: English
//  with spaces, Spanish with newlines. Combined with filters that shrank only the Spanish side,
//  the correspondence between an original and its translation was unrecoverable.
//
//  Decision Q2 keeps the two-text-block schema and no data migration, so correspondence is
//  POSITIONAL BY LINE NUMBER. That requires both blocks to use the same separator and to have
//  the same number of lines — which this type is responsible for guaranteeing.
//
//  Pure, stateless, no I/O. Called on save and on export, never on the ASR hot path.
//

import Foundation

enum ConversationTextFormatter {

    /// Separator for BOTH blocks. Not a style choice — the positional guarantee depends on it.
    nonisolated static var lineSeparator: String { "\n" }

    static let englishHeader = "=== ENGLISH TRANSCRIPT ==="
    static let spanishHeader = "=== SPANISH TRANSLATION ==="

    /// Marker for an absent translation. The line is NEVER omitted: omitting it is exactly the
    /// defect that made a missing translation indistinguishable from silence.
    nonisolated static func unavailableMarker(_ reason: TranslationOutcome.Reason) -> String {
        "[traducción no disponible: \(reason.shortDescription)]"
    }

    // MARK: - Blocks

    /// One line per fragment. Internal newlines are collapsed so a fragment can never occupy
    /// two lines and silently break the alignment.
    nonisolated static func englishBlock(_ fragments: [ConversationFragment]) -> String {
        fragments
            .map { flatten($0.sourceText) }
            .joined(separator: lineSeparator)
    }

    /// One line per fragment, with a marker where a translation is missing.
    /// GUARANTEE: same line count as `englishBlock` for the same input.
    nonisolated static func spanishBlock(_ fragments: [ConversationFragment]) -> String {
        fragments
            .map { fragment in
                switch fragment.translation {
                case .translated(let text):    return flatten(text)
                case .unavailable(let reason): return unavailableMarker(reason)
                // Unreachable in practice: the stop drain converts every pending fragment to
                // `.timedOut` first. Handled rather than force-unwrapped so a future caller
                // cannot break the line-count invariant by accident.
                case .pending:                 return unavailableMarker(.timedOut)
                }
            }
            .joined(separator: lineSeparator)
    }

    // MARK: - Document

    nonisolated static func exportDocument(_ fragments: [ConversationFragment]) -> String {
        let english = englishBlock(fragments)
        let spanish = spanishBlock(fragments)
        return exportDocument(english: english, spanish: spanish)
    }

    /// Overload for already-persisted conversations, which are plain text by then.
    nonisolated static func exportDocument(english: String, spanish: String) -> String {
        let en = english.isEmpty ? "(no transcript)" : english
        let es = spanish.isEmpty ? "(no translation)" : spanish
        return "\(englishHeader)\n\n\(en)\n\n\(spanishHeader)\n\n\(es)"
    }

    // MARK: - Invariant checks

    /// The invariant behind SC-020. `SaveConversationUseCase` asserts it before persisting and
    /// the telemetry reports the result.
    nonisolated static func linesAreAligned(english: String, spanish: String) -> Bool {
        lineCount(english) == lineCount(spanish)
    }

    nonisolated static func lineCount(_ text: String) -> Int {
        text.isEmpty ? 0 : text.components(separatedBy: lineSeparator).count
    }

    /// Conversations saved before this feature: English joined with spaces, line counts
    /// unrelated. They render and export without error but carry no positional guarantee.
    ///
    /// No attempt is made to infer the pairing. There is no reliable heuristic, and a wrong
    /// inference would be worse than honestly not offering the guarantee (FR-044).
    nonisolated static func isLegacyFormat(english: String, spanish: String) -> Bool {
        guard !english.isEmpty, !spanish.isEmpty else { return false }
        return lineCount(english) != lineCount(spanish)
    }

    // MARK: - Helpers

    /// Collapses any internal newline so one fragment is always exactly one line.
    private nonisolated static func flatten(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}
