//
//  AudioRingBufferTests.swift
//  TranslatorAppTests
//
//  The carry-over window after a route change (research 2026-09-15, finding A2). The pool was
//  allocated for the first format it ever saw and then silently refused everything else, so
//  after connecting headphones every rotation replayed stale audio — or none.
//

import AVFoundation
import XCTest
@testable import TranslatorApp

final class AudioRingBufferTests: XCTestCase {

    private func buffer(rate: Double, frames: AVAudioFrameCount, value: Float) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        let samples = buffer.floatChannelData![0]
        for index in 0..<Int(frames) { samples[index] = value }
        return buffer
    }

    func testRingBufferFollowsAFormatChange() {
        let ring = AudioRingBuffer(capacitySeconds: 1.0)
        for _ in 0..<10 { ring.append(buffer(rate: 48_000, frames: 1_024, value: 0.1)) }
        for _ in 0..<5 { ring.append(buffer(rate: 16_000, frames: 1_600, value: 0.5)) }

        let drained = ring.drain()
        XCTAssertFalse(drained.isEmpty, "the new format was refused entirely")
        XCTAssertTrue(drained.allSatisfy { $0.format.sampleRate == 16_000 },
                      "audio from before the route change was replayed: \(drained.map(\.format.sampleRate))")
        XCTAssertEqual(drained.last?.floatChannelData?[0][0], 0.5)
    }

    /// A rotation that is not a deaf one only replays the swap window, never the whole store.
    func testDrainCanReturnOnlyTheNewestAudio() {
        let ring = AudioRingBuffer(capacitySeconds: 6.0)
        for index in 0..<10 { ring.append(buffer(rate: 48_000, frames: 1_024, value: Float(index))) }

        // 50 ms at 48 kHz is 2 400 frames: three 1 024-frame buffers are the fewest that cover it.
        let drained = ring.drain(lastMs: 50)
        XCTAssertEqual(drained.count, 3)
        XCTAssertEqual(drained.map { $0.floatChannelData![0][0] }, [7, 8, 9], "oldest-first, newest kept")
    }

    /// The deaf watchdog fires after 4 s without text; the window must still hold that speech.
    func testWindowCoversTheDeafTimeout() {
        let ring = AudioRingBuffer(capacitySeconds: AppleSFSpeechEngine.carryOverCapacitySeconds)
        // 5 s of 1 024-frame buffers at 48 kHz.
        for _ in 0..<235 { ring.append(buffer(rate: 48_000, frames: 1_024, value: 0.2)) }

        let replayMs = AppleSFSpeechEngine.replayWindowMs(trigger: .deaf,
                                                          msSinceLastTranscript: AppleSFSpeechEngine.deafTimeoutMs)
        let frames = ring.drain(lastMs: replayMs).reduce(0) { $0 + Int($1.frameLength) }
        XCTAssertGreaterThanOrEqual(Double(frames) / 48.0, Double(AppleSFSpeechEngine.deafTimeoutMs),
                                    "the replay must cover the speech the silent request never transcribed")
    }

    func testBufferLargerThanTheFirstOneIsKept() {
        let ring = AudioRingBuffer(capacitySeconds: 1.0)
        ring.append(buffer(rate: 48_000, frames: 512, value: 0.1))
        ring.append(buffer(rate: 48_000, frames: 4_096, value: 0.7))

        let drained = ring.drain()
        XCTAssertTrue(drained.contains { $0.frameLength == 4_096 },
                      "a buffer larger than the first one was dropped: \(drained.map(\.frameLength))")
    }
}
