//
//  SpeechRepository.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 14/02/26.
//
import Speech
import AVFoundation
import OSLog

final class SpeechRepository: SpeechRepositoryProtocol {
    private let listener: ContinuousSpeechListener
    init(listener: ContinuousSpeechListener) { self.listener = listener }
    func startTranscription() async throws -> AsyncStream<SpeechSegment> { try await listener.start() }
    func stopTranscription() async { await listener.stop() }
}
