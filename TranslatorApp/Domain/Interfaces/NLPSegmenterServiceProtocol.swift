//
//  NLPSegmenterServiceProtocol.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

protocol NLPSegmenterServiceProtocol {
    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<String>
    var committedFullText: String { get }
}

