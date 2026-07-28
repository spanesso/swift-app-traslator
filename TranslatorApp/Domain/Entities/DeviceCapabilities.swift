//
//  DeviceCapabilities.swift
//  TranslatorApp
//
//  Synchronous device capability checks used by engine selection and corrector gate.

import Foundation

enum DeviceCapabilities {
    /// True on iPhone 15 Pro / 15 Pro Max (A17 Pro) and any newer iPhone (A18+).
    /// Used to gate the Foundation Models corrector.
    ///
    /// `nonisolated` because actors read it: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// it would otherwise be MainActor-isolated, which is an error in the Swift 6 language mode.
    nonisolated static var supportsA17Pro: Bool {
        #if targetEnvironment(simulator)
        // Allow testing in simulator by checking an env override
        return ProcessInfo.processInfo.environment["SIMULATE_A17PRO"] == "1"
        #else
        var sysInfo = utsname()
        uname(&sysInfo)
        let machine: String = withUnsafePointer(to: &sysInfo.machine) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        // iPhone16,* = iPhone 15 Pro/Max (A17 Pro)
        // iPhone17,* = iPhone 16 family (A18/A18 Pro)
        // iPhone18,* = iPhone 17 family and later
        return machine.hasPrefix("iPhone16,") ||
               machine.hasPrefix("iPhone17,") ||
               machine.hasPrefix("iPhone18,")
        #endif
    }

    /// True on iOS 26 and later, where SpeechAnalyzer and Foundation Models are available.
    nonisolated static var supportsEnhancedFrameworks: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}
