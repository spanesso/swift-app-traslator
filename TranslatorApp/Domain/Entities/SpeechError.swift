//
//  Domain.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import Foundation
import AVFoundation
import Speech

// Error Handling
enum SpeechError: Error, LocalizedError {
    case notAuthorized
    case engineConfigurationFailed
    
    var errorDescription: String? {
        switch self {
        case .notAuthorized: return "Permissions denied for microphone or speech."
        case .engineConfigurationFailed: return "Could not start audio engine."
        }
    }
}
