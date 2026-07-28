//
//  AudioRingBuffer.swift
//  TranslatorApp
//
//  Carry-over buffer that covers a recogniser swap (feature 006, reworked in 008 §R5).
//
//  WHAT CHANGED IN 008
//  The previous version allocated a fresh `AVAudioPCMBuffer` for every buffer arriving from the
//  microphone — i.e. it called `malloc` on the real-time audio render thread, tens of times a
//  second. Allocation there can block for an unbounded time and is a textbook cause of dropped
//  buffers. The old file's comment justified the lock but never mentioned the allocation.
//
//  Now the storage is preallocated once, when the first buffer arrives and the format is known.
//  The render thread only does `memcpy` into an existing slot plus a few integer updates under
//  the lock. Nothing is allocated, freed, or grown on that thread.
//
//  `drain()` still hands out freshly copied buffers — but it runs on the actor during a
//  rotation, not on the audio thread, so allocating there is free of consequence. Copying is
//  required for safety: the slots are recycled immediately afterwards, and a recognition
//  request holding onto them would read audio being overwritten underneath it.
//
//  Everything is `nonisolated`: with `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` these members
//  would otherwise be MainActor-isolated, and every call from the render thread would be an
//  isolation violation that no lock can make safe.
//

import AVFoundation
import Foundation

/// Thread-safe rolling store of recently captured audio.
///
/// A lock-based class rather than an `actor` on purpose: it is written from the real-time audio
/// tap callback, which cannot `await` actor isolation without dropping frames. The lock is held
/// only for a `memcpy` and a few integer updates — never across allocation or Swift concurrency
/// suspension. A deliberate, non-casual use of `@unchecked Sendable`.
/// `nonisolated` on the type, not just on its methods: with
/// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` the stored properties would otherwise be
/// MainActor-isolated, and touching them from the render thread would be an isolation
/// violation no lock can make safe. The lock — not the actor system — is what provides safety
/// here, which is the whole reason this is not an actor.
nonisolated final class AudioRingBuffer: @unchecked Sendable {

    private let lock = NSLock()
    private let capacitySeconds: Double

    // Guarded by `lock`.
    private var slots: [AVAudioPCMBuffer] = []
    private var frameCounts: [AVAudioFrameCount] = []
    private var writeIndex = 0
    private var filled = 0
    private var bufferedFrames: AVAudioFramePosition = 0
    private var evictedSinceReport = 0

    /// - Parameter capacitySeconds: rolling window length. Must exceed the worst-case swap
    ///   latency. Default 1.5 s.
    nonisolated init(capacitySeconds: Double = 1.5) {
        self.capacitySeconds = capacitySeconds
    }

    /// Copies the latest tap buffer into a preallocated slot. Safe to call from the audio thread.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        lock.lock(); defer { lock.unlock() }

        if slots.isEmpty {
            allocateStorageLocked(like: buffer)
            guard !slots.isEmpty else { return }
        }
        guard Self.formatsMatch(slots[0].format, buffer.format) else { return }

        let index = writeIndex
        guard Self.copySamples(from: buffer, to: slots[index]) else { return }

        if filled == slots.count {
            bufferedFrames -= AVAudioFramePosition(frameCounts[index])
            evictedSinceReport += 1
        } else {
            filled += 1
        }
        frameCounts[index] = buffer.frameLength
        bufferedFrames += AVAudioFramePosition(buffer.frameLength)
        writeIndex = (index + 1) % slots.count
    }

    /// Returns the buffered audio oldest-first and clears the store.
    ///
    /// Called once per rotation, from the actor — never from the audio thread — so the copies
    /// made here are safe to allocate. They ARE copies precisely because the slots are recycled
    /// the moment this returns.
    nonisolated func drain() -> [AVAudioPCMBuffer] {
        lock.lock()
        var ordered: [(AVAudioPCMBuffer, AVAudioFrameCount)] = []
        if filled > 0 {
            let total = slots.count
            let start = (writeIndex - filled + total) % total
            ordered.reserveCapacity(filled)
            for offset in 0..<filled {
                let index = (start + offset) % total
                ordered.append((slots[index], frameCounts[index]))
            }
        }
        filled = 0
        writeIndex = 0
        bufferedFrames = 0
        lock.unlock()

        return ordered.compactMap { slot, frames in
            guard let copy = AVAudioPCMBuffer(pcmFormat: slot.format, frameCapacity: frames) else {
                return nil
            }
            return Self.copySamples(from: slot, to: copy, frames: frames) ? copy : nil
        }
    }

    /// Drops everything without returning it (user stop).
    nonisolated func reset() {
        lock.lock(); defer { lock.unlock() }
        filled = 0
        writeIndex = 0
        bufferedFrames = 0
    }

    /// Snapshot for telemetry. Reading it also clears the eviction counter.
    nonisolated func snapshot() -> (bufferedMs: Int, bufferCount: Int, evicted: Int) {
        lock.lock(); defer { lock.unlock() }
        guard let first = slots.first, first.format.sampleRate > 0 else { return (0, 0, 0) }
        let ms = Int(Double(bufferedFrames) / first.format.sampleRate * 1000.0)
        let evicted = evictedSinceReport
        evictedSinceReport = 0
        return (ms, filled, evicted)
    }

    // MARK: - Storage

    /// Allocates the whole pool once, on the first buffer, when the format is finally known.
    /// This is the only allocation the audio thread ever performs — one time per session.
    private nonisolated func allocateStorageLocked(like buffer: AVAudioPCMBuffer) {
        let framesPerBuffer = max(Int(buffer.frameLength), 1)
        let capacityFrames = Int(capacitySeconds * buffer.format.sampleRate)
        // One extra slot so the window stays fully covered after integer truncation.
        let slotCount = max(capacityFrames / framesPerBuffer + 1, 2)

        var pool: [AVAudioPCMBuffer] = []
        pool.reserveCapacity(slotCount)
        for _ in 0..<slotCount {
            guard let slot = AVAudioPCMBuffer(pcmFormat: buffer.format,
                                              frameCapacity: buffer.frameCapacity) else { return }
            pool.append(slot)
        }
        slots = pool
        frameCounts = Array(repeating: 0, count: slotCount)
        writeIndex = 0
        filled = 0
        bufferedFrames = 0
    }

    private nonisolated static func formatsMatch(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate
            && a.channelCount == b.channelCount
            && a.commonFormat == b.commonFormat
    }

    /// Raw sample copy. No allocation — this is what runs on the render thread.
    private nonisolated static func copySamples(from source: AVAudioPCMBuffer,
                                                to destination: AVAudioPCMBuffer,
                                                frames: AVAudioFrameCount? = nil) -> Bool {
        let frameCount = frames ?? source.frameLength
        guard frameCount <= destination.frameCapacity else { return false }
        destination.frameLength = frameCount
        let channels = Int(source.format.channelCount)
        let count = Int(frameCount)

        if let src = source.floatChannelData, let dst = destination.floatChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], count * MemoryLayout<Float>.size) }
        } else if let src = source.int16ChannelData, let dst = destination.int16ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], count * MemoryLayout<Int16>.size) }
        } else if let src = source.int32ChannelData, let dst = destination.int32ChannelData {
            for ch in 0..<channels { memcpy(dst[ch], src[ch], count * MemoryLayout<Int32>.size) }
        } else {
            return false
        }
        return true
    }
}
