//
//  ModelInstallState.swift
//  TranslatorApp
//

import Foundation

/// State machine for the BackgroundAssets-managed WhisperKit model download.
/// Only the transitions listed in data-model.md §1.6 are legal; all others are bugs.
enum ModelInstallState: Sendable, Equatable, CustomStringConvertible {
    case notRequested
    case awaitingConsent
    case downloading(progress: Double)
    case installed(version: String, sizeBytes: Int64)
    case declined
    case failed(reason: ModelInstallFailure)

    static func == (lhs: ModelInstallState, rhs: ModelInstallState) -> Bool {
        switch (lhs, rhs) {
        case (.notRequested, .notRequested): return true
        case (.awaitingConsent, .awaitingConsent): return true
        case (.downloading(let a), .downloading(let b)): return a == b
        case (.installed(let v1, let s1), .installed(let v2, let s2)): return v1 == v2 && s1 == s2
        case (.declined, .declined): return true
        case (.failed(let a), .failed(let b)): return a == b
        default: return false
        }
    }

    var isTerminal: Bool {
        switch self {
        case .installed, .declined: return true
        default: return false
        }
    }

    var progressIfDownloading: Double? {
        if case .downloading(let p) = self { return p }
        return nil
    }

    var description: String {
        switch self {
        case .notRequested:               return "notRequested"
        case .awaitingConsent:            return "awaitingConsent"
        case .downloading(let p):         return "downloading(\(Int(p * 100))%)"
        case .installed(let v, _):        return "installed(\(v))"
        case .declined:                   return "declined"
        case .failed(let r):              return "failed(\(r.rawValue))"
        }
    }
}

/// Reasons a model download can fail.
enum ModelInstallFailure: String, Sendable, Equatable, Codable {
    case networkUnavailable
    case deviceUnsupported   // device is older than A17 Pro
    case insufficientStorage
    case canceled
    case unknown

    var userFacingMessage: String {
        switch self {
        case .networkUnavailable: return "No internet connection. Please connect to Wi-Fi and try again."
        case .deviceUnsupported: return "Enhanced accuracy requires an iPhone 15 Pro or newer."
        case .insufficientStorage: return "Not enough storage. Free up space and try again."
        case .canceled: return "Download was canceled."
        case .unknown: return "An unexpected error occurred. Please try again."
        }
    }
}
