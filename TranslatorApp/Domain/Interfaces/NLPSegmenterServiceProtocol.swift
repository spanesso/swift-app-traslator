//
//  NLPSegmenterServiceProtocol.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//

protocol NLPSegmenterServiceProtocol {
    func processStream(_ stream: AsyncStream<SpeechSegment>) -> AsyncStream<String>
<<<<<<< HEAD
    var committedFullText: String { get }
=======
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
}

