//
//  AccentGroup.swift
//  TranslatorApp
//

import Foundation

/// Terms fed to the recogniser as context, so it expects them instead of guessing.
///
/// WHY THIS MATTERS FOR A QUIET SPEAKER
/// The reason a human understands someone at the far end of the table and the recogniser does
/// not is NOT loudness — amplifying raises the voice and the room noise equally and leaves the
/// signal-to-noise ratio untouched. It is that a person reconstructs half-heard words from
/// context. This is the one way to hand the recogniser some of that same context: told in
/// advance that "microprocessor" and "high voltage" are likely, it needs far less acoustic
/// evidence to commit to them.
///
/// This existed before feature 008 and was lost when the three duplicate engines were merged
/// into one. Restored here as its own type so it has an obvious home to grow in.
///
/// Apple caps the list at 100 short phrases. Beyond that, and with terms that do not actually
/// occur, biasing HURTS: the recogniser starts hearing them where they were not said.
enum ContextualVocabulary {

    /// Domain terms for the meetings this app is used in. Deliberately empty until filled with
    /// real vocabulary — a wrong list is worse than no list.
    nonisolated static var terms: [String] { userTerms + Self.persisted }

    /// Seeded in code. Replace with the project's own words: product names, component names,
    /// acronyms, and the names of the people who attend.
    private nonisolated static var userTerms: [String] { [] }

    // MARK: - Persistence

    private nonisolated static var defaultsKey: String { "asr.contextualVocabulary" }

    /// Terms the user added at runtime, so the list can grow without a rebuild.
    nonisolated static var persisted: [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
    }

    nonisolated static func save(_ terms: [String]) {
        let cleaned = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        UserDefaults.standard.set(Array(cleaned.prefix(maxTerms)), forKey: defaultsKey)
    }

    /// Apple's documented ceiling. Past it the extra entries are ignored anyway.
    nonisolated static var maxTerms: Int { 100 }
}

/// Coarse accent label used by the diagnostic harness and optionally as a runtime
/// biasing hint when the user has set a preference (FR-013).
enum AccentGroup: String, Sendable, Codable, CaseIterable {
    case native           // baseline / regression guard
    case italian
    case indianSouthAsian
    case latino           // Spanish-influenced English
    case other            // best-effort; not in headline SC-001 metrics
    case unknown          // when no detection or preference has been set
}
