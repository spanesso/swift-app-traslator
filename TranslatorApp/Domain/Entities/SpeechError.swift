//
//  SpeechError.swift
//  TranslatorApp
//
//  Domain-pure error type — imports Foundation only.
//  (The original Domain.swift mixed AVFoundation + Speech here; removed in 005-accent-robust-asr.)

import Foundation

enum SpeechError: Error, LocalizedError, Sendable {
    case notAuthorized
    case engineConfigurationFailed
    // Added in 005-accent-robust-asr
    case modelUnavailable
    case deviceUnsupported
    case downloadFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAuthorized:
            return "Microphone or speech recognition access is required."
        case .engineConfigurationFailed:
            return "Could not start the audio engine. Please try again."
        case .modelUnavailable:
            return "The enhanced accuracy model is not installed."
        case .deviceUnsupported:
            return "This feature requires an iPhone 15 Pro or newer."
        case .downloadFailed(let reason):
            return "Model download failed: \(reason)"
        }
    }
}
