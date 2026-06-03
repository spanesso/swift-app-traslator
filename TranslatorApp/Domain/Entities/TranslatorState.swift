//
//  TranslatorState.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

enum TranslatorState: Equatable {
    case idle
    case inFlight
    case error
    case permissionDenied
    case modelUnavailable
    case modelDownloading(progress: Double)
}
