//
//  EnginePreference.swift
//  TranslatorApp
//

import Foundation

/// User-selectable engine policy. Persisted in UserDefaults.
enum EnginePreference: String, Sendable, Codable, CaseIterable {
    case auto             // pick best available engine (default)
    case appleOnly        // force Tier 0; never download WhisperKit
    case whisperPreferred // force Tier 1 when model is installed

    // MARK: - UserDefaults persistence

    private static let defaultsKey = "engine.preference"

    static func fromUserDefaults() -> EnginePreference {
        guard let raw = UserDefaults.standard.string(forKey: defaultsKey),
              let pref = EnginePreference(rawValue: raw) else { return .auto }
        return pref
    }

    func saveToUserDefaults() {
        UserDefaults.standard.set(rawValue, forKey: EnginePreference.defaultsKey)
    }

    var displayName: String {
        switch self {
        case .auto: return "Auto (recommended)"
        case .appleOnly: return "Apple Only (Lite)"
        case .whisperPreferred: return "Enhanced Accuracy"
        }
    }

    /// Whether this build can actually deliver the option (008 decision Q1).
    ///
    /// The local WhisperKit engine is withdrawn in this phase, so `whisperPreferred` is offered
    /// as unavailable rather than as a choice that silently fails. The case itself is NOT
    /// removed: users already have that raw value stored in preferences and deleting it would
    /// break decoding.
    nonisolated var isAvailable: Bool {
        switch self {
        case .auto, .appleOnly:  return true
        case .whisperPreferred:  return false
        }
    }

    /// Shown next to an unavailable option so the choice is explained, not just greyed out.
    nonisolated var unavailableReason: String? {
        isAvailable
            ? nil
            : "Temporarily unavailable. The on-device model is being reworked and is disabled in this build."
    }
}
