//
//  AudioBufferSink.swift
//  TranslatorApp
//
//  A second consumer for the permanent microphone tap (SpeechAnalyzer migration, 2026-09-15).
//
//  The classic engine reads the tap through `RecognitionRequestBox`. SpeechAnalyzer takes its
//  audio as an async sequence instead, so the tap hands every buffer to whichever consumer is
//  installed here. Nothing installed — the classic engine running — costs one lock and a nil check.
//
//  NOTHING IS RELEASED UNDER THE LOCK (field crash 2026-09-15: EXC_BAD_ACCESS in `clear()`, inside
//  the lock, while the audio converter was being deallocated). The consumer is taken out under
//  the lock and let go after it, and the consumer is an object the engine keeps for its whole life,
//  so a stop does not tear down audio conversion at all.
//

import AVFoundation

protocol AudioBufferConsumer: AnyObject, Sendable {
    /// Called from the tap. The buffer is only valid during the call; consumers copy what they keep.
    nonisolated func accept(_ buffer: AVAudioPCMBuffer)
}

/// Lock-protected, like `AudioRingBuffer` and `RecognitionRequestBox`: the tap cannot `await`.
nonisolated final class AudioBufferSink: @unchecked Sendable {

    private let lock = NSLock()
    private var consumer: (any AudioBufferConsumer)?

    nonisolated init() {}

    nonisolated func install(_ newConsumer: any AudioBufferConsumer) {
        lock.lock()
        let previous = consumer
        consumer = newConsumer
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    nonisolated func clear() {
        lock.lock()
        let previous = consumer
        consumer = nil
        lock.unlock()
        withExtendedLifetime(previous) {}
    }

    nonisolated func deliver(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let current = consumer
        lock.unlock()
        current?.accept(buffer)
    }
}
