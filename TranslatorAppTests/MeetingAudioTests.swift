//
//  MeetingAudioTests.swift
//  TranslatorAppTests
//
//  Recording the meeting's audio, and making sure it stops existing (2026-09-15).
//
//  Two properties are worth a test each:
//  - THE TAP FEEDS EVERYONE. With one consumer slot, whichever attached last got the audio and the
//    other went deaf with no error anywhere — the recogniser or the recorder, depending on order.
//  - THE AUDIO GOES AWAY. It exists until the user decides and not one moment longer, including
//    after a crash, when nobody is left to clean up but the next launch.
//

import AVFoundation
import XCTest
@testable import TranslatorApp

final class MeetingAudioTests: XCTestCase {

    // MARK: - Helpers

    private nonisolated final class CountingConsumer: AudioBufferConsumer, @unchecked Sendable {
        private let lock = NSLock()
        private var received = 0

        nonisolated var count: Int {
            lock.lock(); defer { lock.unlock() }
            return received
        }

        nonisolated func accept(_ buffer: AVAudioPCMBuffer) {
            lock.lock(); received += 1; lock.unlock()
        }
    }

    /// A buffer shaped like the tap's: 48 kHz, Float32, mono.
    private func makeTapBuffer(frames: AVAudioFrameCount = 1024,
                               sampleRate: Double = 48_000) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let samples = try XCTUnwrap(buffer.floatChannelData)[0]
        for frame in 0..<Int(frames) {
            samples[frame] = sin(Float(frame) * 0.05) * 0.5
        }
        return buffer
    }

    private func temporaryAudioURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-test-\(UUID().uuidString).caf")
    }

    // MARK: - The tap feeds every consumer

    func testEveryAttachedConsumerReceivesTheAudio() throws {
        let sink = AudioBufferSink()
        let recogniser = CountingConsumer()
        let recorder = CountingConsumer()
        sink.add(recogniser)
        sink.add(recorder)

        sink.deliver(try makeTapBuffer())

        XCTAssertEqual(sink.count, 2, "both consumers must be attached, not one replacing the other")
        XCTAssertEqual(recogniser.count, 1, "the recogniser stopped receiving audio")
        XCTAssertEqual(recorder.count, 1, "the recorder stopped receiving audio")
    }

    func testRemovingOneConsumerLeavesTheOtherRecording() throws {
        let sink = AudioBufferSink()
        let recogniser = CountingConsumer()
        let recorder = CountingConsumer()
        sink.add(recogniser)
        sink.add(recorder)
        sink.deliver(try makeTapBuffer())

        // What the engine does when it stops: it detaches ITSELF.
        sink.remove(recogniser)
        sink.deliver(try makeTapBuffer())

        XCTAssertEqual(recogniser.count, 1, "a detached consumer must receive nothing more")
        XCTAssertEqual(recorder.count, 2, "the engine stopping must not silence the recorder")
    }

    func testAttachingTheSameConsumerTwiceDeliversOnce() throws {
        let sink = AudioBufferSink()
        let consumer = CountingConsumer()
        sink.add(consumer)
        sink.add(consumer)

        sink.deliver(try makeTapBuffer())

        XCTAssertEqual(sink.count, 1)
        XCTAssertEqual(consumer.count, 1)
    }

    // MARK: - The file

    func testWriterProducesAReadable16kHzMonoFile() throws {
        let url = temporaryAudioURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let writer = MeetingAudioWriter()
        try writer.open(url: url)
        XCTAssertTrue(writer.isRecording)

        // ~2.1 s of tap audio.
        let buffers = 100
        for _ in 0..<buffers { writer.accept(try makeTapBuffer()) }
        let stats = writer.close()

        XCTAssertFalse(writer.isRecording)
        XCTAssertEqual(stats.droppedBuffers, 0, "nothing should be dropped writing two seconds")
        XCTAssertEqual(stats.writeFailures, 0)

        let expectedMs = Int(Double(buffers * 1024) / 48_000.0 * 1000.0)
        XCTAssertEqual(stats.durationMs, expectedMs, accuracy: 100,
                       "the file must hold the audio that was fed to it")

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.fileFormat.sampleRate, 16_000, "diarisation and the recogniser both want 16 kHz")
        XCTAssertEqual(file.fileFormat.channelCount, 1)
        XCTAssertEqual(Int(file.length), Int(stats.framesWritten),
                       "every frame counted must be a frame on disk")
    }

    func testWriterThatCannotOpenItsFileNeverTakesTheMeetingDown() throws {
        let writer = MeetingAudioWriter()
        let unwritable = URL(fileURLWithPath: "/meeting-audio-not-writable/session.caf")

        XCTAssertThrowsError(try writer.open(url: unwritable))
        XCTAssertFalse(writer.isRecording)
        // The tap keeps calling: this must be a no-op, not a crash.
        writer.accept(try makeTapBuffer())
        XCTAssertEqual(writer.close().framesWritten, 0)
    }

    // MARK: - The audio stops existing

    private func makeStore() -> (MeetingAudioStore, AudioBufferSink) {
        let sink = AudioBufferSink()
        return (MeetingAudioStore(sink: sink, telemetry: NoopPipelineTelemetry()), sink)
    }

    private func record(_ store: MeetingAudioStore,
                        _ sink: AudioBufferSink,
                        session: String,
                        buffers: Int = 30) async throws -> MeetingAudioRecording? {
        await store.beginSession(id: session)
        for _ in 0..<buffers { sink.deliver(try makeTapBuffer()) }
        return await store.finishSession()
    }

    func testAudioIsKeptWhenTheMeetingEndsAndShreddedWhenTheUserDecides() async throws {
        let (store, sink) = makeStore()
        let session = "AUD1"

        let recording = try await record(store, sink, session: session)

        let kept = try XCTUnwrap(recording, "the audio must survive the end of the meeting")
        XCTAssertEqual(kept.sessionId, session)
        XCTAssertGreaterThan(kept.durationMs, 0)
        XCTAssertGreaterThan(kept.bytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.url.path))
        XCTAssertTrue(BackupExclusion.isExcluded(kept.url.deletingLastPathComponent()),
                      "the meeting's audio may never ride along in a backup")

        await store.shred(sessionId: session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: kept.url.path),
                       "nothing of the audio may be left once the user has decided")
        let afterShredding = await store.recording(for: session)
        XCTAssertNil(afterShredding)
    }

    func testAMeetingThatCapturedNoAudioLeavesNoFile() async throws {
        let (store, _) = makeStore()
        let session = "AUD2"

        await store.beginSession(id: session)
        let recording = await store.finishSession()

        XCTAssertNil(recording, "an empty audio file is only a privacy liability")
        let leftover = await store.recording(for: session)
        XCTAssertNil(leftover)
    }

    func testAtLaunchOrphanedAudioIsShreddedAndTheRecoverableMeetingIsKept() async throws {
        let (store, sink) = makeStore()
        let crashed = "AUD3"
        let recoverable = "AUD4"
        _ = try await record(store, sink, session: crashed)
        _ = try await record(store, sink, session: recoverable)

        // What the next launch does: the journal has one meeting pending, everything else is litter.
        await store.shredEverything(except: recoverable)

        let orphan = await store.recording(for: crashed)
        XCTAssertNil(orphan, "audio a crash left behind must not outlive its meeting")
        let waiting = await store.recording(for: recoverable)
        XCTAssertNotNil(waiting, "the meeting the user has still to decide about keeps its audio")

        await store.shredEverything(except: nil)
    }

    func testAudioOfEveryMeetingIsShreddedWhenNothingIsRecoverable() async throws {
        let (store, sink) = makeStore()
        let session = "AUD5"
        _ = try await record(store, sink, session: session)

        await store.shredEverything(except: nil)

        let leftover = await store.recording(for: session)
        XCTAssertNil(leftover)
    }
}
