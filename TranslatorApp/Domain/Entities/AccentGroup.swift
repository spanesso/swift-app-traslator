//
//  AccentGroup.swift
//  TranslatorApp
//

import Foundation

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
