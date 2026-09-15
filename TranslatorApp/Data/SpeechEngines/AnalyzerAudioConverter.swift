//
//  AnalyzerAudioConverter.swift
//  TranslatorApp
//
//  Converts microphone buffers to the format SpeechAnalyzer asks for and feeds them to it
//  (SpeechAnalyzer migration, 2026-09-15).
//
//  The tap delivers the hardware format (typically 48 kHz Float32); the analyser wants its own
//  (typically 16 kHz Int16). The converter is rebuilt only when the input format changes
//  (headphones connected), and is fed with `.noDataNow` rather than `.endOfStream` so the
//  resampler keeps its state between buffers instead of clicking at every boundary.
//
//  OWNED AUDIO ONLY (field crash 2026-09-15). The tap's buffer belongs to the audio engine and is
//  reused after its callback, but a resampler keeps its last input for the frames it has not
//  consumed yet. Each buffer is therefore copied before it is handed to the converter, and one
//  instance lives for the engine's whole life — reconfigured per session, never torn down by a
//  stop.
//

import AVFoundation
import Speech

nonisolated final class AnalyzerAudioConverter: AudioBufferConsumer, @unchecked Sendable {

    /// Guards everything below. The tap delivers from one thread at a time, but a rebuilt tap may
    /// deliver from a different one, and sessions are configured from the engine's actor.
    private let lock = NSLock()
    private var targetFormat: AVAudioFormat?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?

    nonisolated init() {}

    /// Points the converter at a new session.
    nonisolated func configure(targetFormat: AVAudioFormat, continuation: AsyncStream<AnalyzerInput>.Continuation) {
        lock.lock()
        defer { lock.unlock() }
        if self.targetFormat != targetFormat {
            converter = nil
            sourceFormat = nil
        }
        self.targetFormat = targetFormat
        self.continuation = continuation
    }

    /// Stops feeding. Nothing is released here: the converter is kept for the next session.
    nonisolated func detach() {
        lock.lock()
        continuation = nil
        lock.unlock()
    }

    nonisolated func accept(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, let owned = Self.copy(buffer) else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let targetFormat, let continuation else { return }

        if sourceFormat != owned.format || converter == nil {
            converter = AVAudioConverter(from: owned.format, to: targetFormat)
            converter?.primeMethod = .none
            sourceFormat = owned.format
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / owned.format.sampleRate
        let capacity = AVAudioFrameCount((Double(owned.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        // The input block is typed `@Sendable`, but `convert` calls it synchronously, on this
        // thread, before returning: neither the buffer nor the flag is ever shared.
        nonisolated(unsafe) let input = owned
        nonisolated(unsafe) var delivered = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if delivered {
                inputStatus.pointee = .noDataNow
                return nil
            }
            delivered = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, output.frameLength > 0 else { return }
        continuation.yield(AnalyzerInput(buffer: output))
    }

    /// A copy the audio engine cannot reuse underneath us.
    private nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            return nil
        }
        copy.frameLength = buffer.frameLength
        let channels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        if let source = buffer.floatChannelData, let target = copy.floatChannelData {
            for channel in 0..<channels {
                memcpy(target[channel], source[channel], frames * MemoryLayout<Float>.size)
            }
        } else if let source = buffer.int16ChannelData, let target = copy.int16ChannelData {
            for channel in 0..<channels {
                memcpy(target[channel], source[channel], frames * MemoryLayout<Int16>.size)
            }
        } else {
            return nil
        }
        return copy
    }
}
