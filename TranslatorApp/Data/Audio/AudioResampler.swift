//
//  AudioResampler.swift
//  TranslatorApp
//
//  The one implementation of "copy the tap's buffer, then resample it"
//  (extracted from AnalyzerAudioConverter for the meeting-audio recorder, 2026-09-15).
//
//  Two consumers of the tap now need the same conversion — SpeechAnalyzer wants 16 kHz for its
//  model, the recorder wants 16 kHz so an hour of meeting is 115 MB instead of 1.3 GB — and this
//  is code that has already crashed once in the field. It exists once.
//
//  OWNED AUDIO ONLY (field crash 2026-09-15, EXC_BAD_ACCESS). The tap's buffer belongs to the audio
//  engine and is reused after its callback returns, but a resampler keeps its last input for the
//  frames it has not consumed yet. Every buffer is therefore copied before the converter sees it.
//
//  NOT THREAD-SAFE BY DESIGN. An `AVAudioConverter` keeps resampler state between calls, so the
//  owner serialises access with its own lock — the same lock it uses for its target format and its
//  output. Giving this type its own lock would invite a second, redundant one around it.
//

import AVFoundation

nonisolated final class AudioResampler: @unchecked Sendable {

    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    nonisolated init() {}

    /// Forgets the converter. The next `convert` builds one; resampler state is not carried across.
    nonisolated func reset() {
        converter = nil
        sourceFormat = nil
        targetFormat = nil
    }

    /// Resamples one tap buffer. Returns nil when there is nothing to deliver — an empty buffer, a
    /// format that cannot be converted, or a conversion error — and never throws into the tap.
    ///
    /// Fed with `.noDataNow` rather than `.endOfStream` so the resampler keeps its state between
    /// buffers instead of clicking at every boundary.
    nonisolated func convert(_ buffer: AVAudioPCMBuffer, to target: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard buffer.frameLength > 0, let owned = Self.copy(buffer) else { return nil }

        if sourceFormat != owned.format || targetFormat != target || converter == nil {
            converter = AVAudioConverter(from: owned.format, to: target)
            converter?.primeMethod = .none
            sourceFormat = owned.format
            targetFormat = target
        }
        guard let converter else { return nil }

        let ratio = target.sampleRate / owned.format.sampleRate
        let capacity = AVAudioFrameCount((Double(owned.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }

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
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }

    /// A copy the audio engine cannot reuse underneath us.
    nonisolated static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
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
        } else if let source = buffer.int32ChannelData, let target = copy.int32ChannelData {
            for channel in 0..<channels {
                memcpy(target[channel], source[channel], frames * MemoryLayout<Int32>.size)
            }
        } else {
            return nil
        }
        return copy
    }
}
