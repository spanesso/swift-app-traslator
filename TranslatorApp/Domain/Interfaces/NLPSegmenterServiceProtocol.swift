//
//  NLPSegmenterServiceProtocol.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

protocol NLPSegmenterServiceProtocol {
    // processStream is async because NLPSegmenterService is an actor
    func processStream(_ stream: AsyncStream<SpeechSegment>) async -> AsyncStream<String>
}
