//
//  MeetingAudioWriter.swift
//  TranslatorApp
//
//  Writes the meeting's audio to disk from the microphone tap (2026-09-15).
//
//  16 kHz, mono, linear PCM 16-bit, in a CAF file. Three deliberate choices:
//  - 16 kHz mono is what speaker diarisation and the recogniser's own model use, and it turns an
//    hour of meeting into ~115 MB instead of the tap's ~1.3 GB.
//  - LINEAR PCM, not AAC. A compressed file killed mid-write is unreadable — the index lands at the
//    end — while PCM cut short loses only the frames that were never written. Audio is not the
//    conversation, but it should not be all-or-nothing either.
//  - CAF, not WAV: no 4 GB ceiling and no header the length has to be patched into afterwards.
//
//  THREADING
//  `accept` runs on the render thread and must not touch the disk. It copies and resamples the
//  buffer there (the copy is required — see `AudioResampler`) and hands it to a serial queue that
//  owns the file. Every file operation, including open and close, happens on that queue, so there is
//  exactly one thread writing.
//
//  A STALLED DISK IS BOUNDED. Buffers waiting to be written are counted; past `maxQueuedBuffers`
//  they are dropped and counted instead of growing memory until the app is killed — which would
//  take the transcript with it. Dropping audio is the acceptable loss here.
//

import AVFoundation
import OSLog

nonisolated final class MeetingAudioWriter: AudioBufferConsumer, @unchecked Sendable {

    nonisolated static var sampleRate: Double { 16_000 }
    /// ~4 s of backlog at the tap's usual buffer size. Past this the disk is not keeping up.
    nonisolated static var maxQueuedBuffers: Int { 200 }

    /// What one recording produced. Read after `close()`.
    nonisolated struct Stats: Sendable, Equatable {
        var framesWritten: Int64 = 0
        var droppedBuffers: Int = 0
        var writeFailures: Int = 0

        var durationMs: Int { Int(Double(framesWritten) / MeetingAudioWriter.sampleRate * 1000.0) }
    }

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "MeetingAudio")
    private let writeQueue = DispatchQueue(label: "com.spanesso.TraslatorApp.meeting-audio", qos: .utility)

    /// Guards the resampler, the target format and the counters. NOT the file: that belongs to
    /// `writeQueue` alone.
    private let lock = NSLock()
    private let resampler = AudioResampler()
    private var targetFormat: AVAudioFormat?
    private var queuedBuffers = 0
    private var stats = Stats()

    /// Touched only on `writeQueue`.
    private var file: AVAudioFile?

    nonisolated init() {}

    // MARK: - Lifecycle

    /// Opens `url` for writing. Throws if the file cannot be created — the caller records the
    /// meeting without audio rather than failing the meeting.
    nonisolated func open(url: URL) throws {
        let opened: AVAudioFile = try writeQueue.sync {
            let file = try AVAudioFile(forWriting: url,
                                       settings: Self.fileSettings,
                                       commonFormat: .pcmFormatInt16,
                                       interleaved: true)
            self.file = file
            return file
        }
        lock.lock()
        targetFormat = opened.processingFormat
        resampler.reset()
        queuedBuffers = 0
        stats = Stats()
        lock.unlock()
    }

    /// Finishes the file and reports what was written. Waits for the queued buffers, so the last
    /// seconds of the meeting are on disk before anything reads the file.
    nonisolated func close() -> Stats {
        lock.lock()
        targetFormat = nil
        lock.unlock()

        // Barrier: everything already queued runs before this, and nothing new is queued because
        // `accept` needs `targetFormat`.
        writeQueue.sync {
            self.file = nil // AVAudioFile flushes and closes as it is released
        }

        lock.lock()
        let final = stats
        resampler.reset()
        lock.unlock()
        return final
    }

    nonisolated var isRecording: Bool {
        lock.lock()
        let recording = targetFormat != nil
        lock.unlock()
        return recording
    }

    // MARK: - Tap

    nonisolated func accept(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        guard let targetFormat else { lock.unlock(); return }
        guard queuedBuffers < Self.maxQueuedBuffers else {
            stats.droppedBuffers += 1
            lock.unlock()
            return
        }
        let converted = resampler.convert(buffer, to: targetFormat)
        if converted != nil { queuedBuffers += 1 }
        lock.unlock()

        guard let converted else { return }
        // `AVAudioPCMBuffer` is not Sendable, but this one was built here and is handed over: the
        // render thread never touches it again. Same argument as `AudioResampler`.
        nonisolated(unsafe) let payload = converted
        writeQueue.async { [weak self] in
            self?.write(payload)
        }
    }

    private nonisolated func write(_ buffer: AVAudioPCMBuffer) {
        defer {
            lock.lock()
            queuedBuffers -= 1
            lock.unlock()
        }
        guard let file else { return }
        do {
            try file.write(from: buffer)
            lock.lock()
            stats.framesWritten += Int64(buffer.frameLength)
            lock.unlock()
        } catch {
            lock.lock()
            stats.writeFailures += 1
            let failures = stats.writeFailures
            lock.unlock()
            // One line, not one per buffer: a failing disk fails for every buffer.
            if failures == 1 {
                logger.error("[MeetingAudio] write failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: - Format

    private nonisolated static var fileSettings: [String: Any] {
        [AVFormatIDKey: Int(kAudioFormatLinearPCM),
         AVSampleRateKey: sampleRate,
         AVNumberOfChannelsKey: 1,
         AVLinearPCMBitDepthKey: 16,
         AVLinearPCMIsFloatKey: false,
         AVLinearPCMIsBigEndianKey: false,
         AVLinearPCMIsNonInterleaved: false]
    }
}
