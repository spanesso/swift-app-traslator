//
//  SpeechSegment.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

struct SpeechSegment {
    let text: String
    let isFinal: Bool
    let confidence: Float
    
    init(text: String, isFinal: Bool, confidence: Float = 1.0) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
    }
}
