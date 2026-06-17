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
}
