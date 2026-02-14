//
//  SpeechRepositoryProtocol.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

protocol SpeechRepositoryProtocol {
    func startTranscription() async throws -> AsyncStream<SpeechSegment>
    func stopTranscription() async
}
