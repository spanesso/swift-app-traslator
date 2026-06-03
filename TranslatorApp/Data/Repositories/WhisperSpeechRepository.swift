//
//  WhisperSpeechRepository.swift
//  TranslatorApp
//

import Foundation

final class WhisperSpeechRepository: SpeechRepositoryProtocol {

    private let listener: WhisperSpeechListener

    init(listener: WhisperSpeechListener) {
        self.listener = listener
    }

    func startTranscription() async throws -> AsyncStream<SpeechSegment> {
        try await listener.start()
    }

    func stopTranscription() async {
        await listener.stop()
    }
}
