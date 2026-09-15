//
//  AudioBufferSink.swift
//  TranslatorApp
//
//  Fan-out for the permanent microphone tap (SpeechAnalyzer migration, 2026-09-15;
//  several consumers since the encrypted meeting-audio phase).
//
//  The classic engine reads the tap through `RecognitionRequestBox`. SpeechAnalyzer takes its audio
//  as an async sequence, and the meeting recorder writes it to disk, so the tap hands every buffer
//  to every consumer attached here. None attached — the classic engine running with recording of
//  audio off — costs one lock and an empty check.
//
//  ONE CONSUMER WAS NOT ENOUGH. `install` used to REPLACE whoever was there, which was fine while
//  the analyser was the only consumer and silently wrong the moment a second one existed: whichever
//  attached last got the audio and the other went deaf with no error anywhere.
//
//  NOTHING IS RELEASED UNDER THE LOCK (field crash 2026-09-15: EXC_BAD_ACCESS in `clear()`, inside
//  the lock, while the audio converter was being deallocated). Consumers are taken out under the
//  lock and let go after it. The list is copy-on-write and never mutated in place, so the snapshot
//  the render thread is iterating cannot change underneath it.
//

import AVFoundation

protocol AudioBufferConsumer: AnyObject, Sendable {
    /// Called from the tap. The buffer is only valid during the call; consumers copy what they keep.
    nonisolated func accept(_ buffer: AVAudioPCMBuffer)
}

/// Lock-protected, like `AudioRingBuffer` and `RecognitionRequestBox`: the tap cannot `await`.
nonisolated final class AudioBufferSink: @unchecked Sendable {

    private let lock = NSLock()
    /// Copy-on-write snapshot. Retaining it on the render thread costs a refcount, not an allocation.
    private var consumers: [any AudioBufferConsumer] = []

    nonisolated init() {}

    /// Attaches a consumer. Attaching the same object twice delivers to it once.
    nonisolated func add(_ consumer: any AudioBufferConsumer) {
        lock.lock()
        let previous = consumers
        if !consumers.contains(where: { $0 === consumer }) {
            consumers = previous + [consumer]
        }
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    /// Detaches one consumer and leaves the others receiving audio.
    nonisolated func remove(_ consumer: any AudioBufferConsumer) {
        lock.lock()
        let previous = consumers
        consumers = previous.filter { $0 !== consumer }
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    /// Detaches everyone. For teardown only — an engine stopping removes ITS consumer, never this,
    /// or it would silence the recorder as a side effect.
    nonisolated func removeAll() {
        lock.lock()
        let previous = consumers
        consumers = []
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    nonisolated var count: Int {
        lock.lock()
        let count = consumers.count
        lock.unlock()
        return count
    }

    nonisolated func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = consumers
        lock.unlock()
        for consumer in current { consumer.accept(buffer) }
    }
}
