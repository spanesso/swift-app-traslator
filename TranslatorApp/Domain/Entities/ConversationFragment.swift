//
//  ConversationFragment.swift
//  TranslatorApp
//
//  The paired unit of a conversation (008-fix-audio-pipeline-resilience, US7).
//
//  Replaces the two parallel arrays the ViewModel used to keep — one of English phrases, one of
//  translated sentences — whose counts were never coupled by any invariant. Four separate
//  filters shrank the Spanish side without touching the English one, and none of them left a
//  trace, so the export could silently lose a translation.
//
//  Decision Q2: this lives in memory only. Persistence keeps the existing two-text-block schema,
//  with correspondence carried by line position.
//

import Foundation

nonisolated struct ConversationFragment: Sendable, Identifiable, Equatable {
    /// Monotonic within the session, from 0. This IS the line index in both exported blocks.
    let id: Int
    /// English source. Non-empty after trimming. Immutable once created.
    let sourceText: String
    var translation: TranslationOutcome
    let sourceConfidence: Float

    nonisolated init(id: Int,
                     sourceText: String,
                     translation: TranslationOutcome = .pending,
                     sourceConfidence: Float = 1.0) {
        self.id = id
        self.sourceText = sourceText
        self.translation = translation
        self.sourceConfidence = sourceConfidence
    }

    nonisolated var isPending: Bool { translation == .pending }

    /// Text to render in the Spanish pane: the translation, or the marker.
    nonisolated var displayTranslation: String {
        switch translation {
        case .pending:                 return ""
        case .translated(let text):    return text
        case .unavailable(let reason): return ConversationTextFormatter.unavailableMarker(reason)
        }
    }
}

/// The state of a fragment's translation.
///
/// THE CENTRAL INVARIANT: a fragment never disappears. A failed translation moves to
/// `.unavailable(reason)` — it is never removed and its line is never omitted. Previously an
/// absent translation was expressed as an `append` that did not happen, which is
/// indistinguishable from "there was nothing there".
nonisolated enum TranslationOutcome: Sendable, Equatable {
    case pending
    case translated(String)
    case unavailable(Reason)

    /// Classifies what came back from the translation service.
    ///
    /// A service handed a fragment it cannot work with may return the input unchanged rather
    /// than fail. Stored as a translation, that is English sitting in the Spanish pane looking
    /// exactly like a real result — which is what the user reported seeing.
    ///
    /// The echo check needs at least three words: plenty of one- and two-word phrases are
    /// genuinely identical in both languages ("No.", "OK.", names, numbers, cognates), and
    /// flagging those would invent a failure that never happened.
    nonisolated static func forResult(_ translated: String, source: String) -> TranslationOutcome {
        let trimmed = translated.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .unavailable(.emptyResult) }

        let sourceWords = source.split(whereSeparator: \.isWhitespace)
        guard sourceWords.count >= 3 else { return .translated(trimmed) }

        let normalizedSource = sourceWords.map { TranscriptWindow.normalize(String($0)) }
        let normalizedResult = trimmed.split(whereSeparator: \.isWhitespace)
            .map { TranscriptWindow.normalize(String($0)) }
        return normalizedSource == normalizedResult
            ? .unavailable(.notTranslated)
            : .translated(trimmed)
    }

    nonisolated enum Reason: String, Sendable, Equatable {
        /// The translation service threw.
        case failed
        /// Discarded before translating because it was too short.
        case tooShort
        /// The service returned empty text.
        case emptyResult
        /// Still unresolved when the stop drain expired.
        case timedOut
        /// `prepareTranslation` failed, so no phrase in the session could be translated.
        case serviceUnavailable
        /// The service handed back the source text unchanged. Storing that as a translation put
        /// English in the Spanish pane, indistinguishable from a real result.
        case notTranslated

        nonisolated var shortDescription: String {
            switch self {
            case .failed:             return "translation failed"
            case .tooShort:           return "too short to translate"
            case .emptyResult:        return "empty result"
            case .timedOut:           return "timed out"
            case .serviceUnavailable: return "translation service unavailable"
            case .notTranslated:      return "not translated"
            }
        }
    }
}
