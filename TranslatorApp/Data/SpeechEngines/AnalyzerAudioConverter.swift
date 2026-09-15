//
//  AnalyzerAudioConverter.swift
//  TranslatorApp
//
//  Feeds the microphone to SpeechAnalyzer in the format it asks for
//  (SpeechAnalyzer migration, 2026-09-15).
//
//  The tap delivers the hardware format (typically 48 kHz Float32); the analyser wants its own
//  (typically 16 kHz). The conversion itself — including the copy that the field crash of
//  2026-09-15 made non-negotiable — lives in `AudioResampler`, shared with the meeting-audio
//  recorder. This type owns the session: which format, which stream, and when it stops feeding.
//
//  One instance lives for the engine's whole life — reconfigured per session, never torn down by a
//  stop — so a stop cannot deallocate audio conversion while the tap is still calling into it.
//

import AVFoundation
import Speech

nonisolated final class AnalyzerAudioConverter: AudioBufferConsumer, @unchecked Sendable {

    /// Guards everything below, including the resampler, which keeps state between buffers. The tap
    /// delivers from one thread at a time, but a rebuilt tap may deliver from a different one, and
    /// sessions are configured from the engine's actor.
    private let lock = NSLock()
    private let resampler = AudioResampler()
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?

    nonisolated init() {}

    /// Points the converter at a new session.
    nonisolated func configure(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        if self.targetFormat != targetFormat { resampler.reset() }
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    /// Stops feeding. Nothing is released here: the resampler is kept for the next session.
    nonisolated func detach() {
        lock.lock()
        continuation = nil
        lock.unlock()
    }

    nonisolated func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        defer { lock.unlock() }
        guard let targetFormat, let continuation else { return }
        guard let output = resampler.convert(buffer, to: targetFormat) else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }
}
