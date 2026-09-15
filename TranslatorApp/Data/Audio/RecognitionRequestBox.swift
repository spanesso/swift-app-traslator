//
//  RecognitionRequestBox.swift
//  TranslatorApp
//
//  Swappable holder for the active recognition request
//  (008-fix-audio-pipeline-resilience, US6 / research §R4).
//
//  WHY THIS EXISTS
//  Rotating the recogniser used to mean tearing the microphone tap down and building it back
//  up. Between `removeTap` and `installTap` nothing was capturing — not the request, not the
//  carry-over ring buffer — so audio spoken during the swap was genuinely lost, and the size of
//  that window depended on system load.
//
//  With this box the tap is installed ONCE per recording session and rotation is a pointer
//  swap. The blind window is not made small; it stops existing.
//
//  CONCURRENCY — the project's single justified `@unchecked Sendable` for this feature (gate G5)
//  The tap closure runs on the real-time audio render thread and must read the active request
//  with no `await`. An actor would force an asynchronous hop per buffer, which is exactly the
//  behaviour that loses audio. `OSAllocatedUnfairLock` is held only across the pointer read and
//  the `append` call — never across allocation, I/O, or Swift concurrency suspension. This is
//  the same reasoning already accepted for `AudioRingBuffer`.
//

import AVFoundation
import Speech
import os

final class RecognitionRequestBox: @unchecked Sendable {

    private let state = OSAllocatedUnfairLock<SFSpeechAudioBufferRecognitionRequest?>(initialState: nil)

    nonisolated init() {}

    /// Installs `request` as the active one and returns the request it replaced, so the caller
    /// can tear the old one down AFTER the new one is already receiving audio.
    @discardableResult
    nonisolated func swap(to request: SFSpeechAudioBufferRecognitionRequest?)
        -> SFSpeechAudioBufferRecognitionRequest? {
        state.withLock { current in
            let previous = current
            current = request
            return previous
        }
    }

    /// Feeds a captured buffer to whichever request is active. Called from the audio thread.
    /// A nil request (between sessions) is a no-op, not an error.
    nonisolated func append(_ buffer: AVAudioPCMBuffer) {
        state.withLock { current in
            current?.append(buffer)
        }
    }

    /// Feeds a captured buffer to the active request AND to the carry-over window, under the same
    /// lock `swap(to:replaying:lastMs:)` takes. Called from the tap.
    ///
    /// Taking them separately left a gap (research 2026-09-15, A5): a buffer could reach the old
    /// request after the window had been drained for the new one, and so reach neither the new
    /// request nor its replay.
    nonisolated func append(_ buffer: AVAudioPCMBuffer, recordingInto ring: AudioRingBuffer) {
        state.withLock { current in
            ring.append(buffer)
            current?.append(buffer)
        }
    }

    /// Replays the newest `lastMs` of the window into `request` and makes it the active one, in
    /// one step with respect to the tap. The tap waits on the lock for the length of a copy.
    ///
    /// - Returns: the request that was replaced, and what was replayed.
    nonisolated func swap(to request: SFSpeechAudioBufferRecognitionRequest,
                          replaying ring: AudioRingBuffer,
                          lastMs: Int)
        -> (previous: SFSpeechAudioBufferRecognitionRequest?, replayedBuffers: Int, replayedMs: Int) {
        state.withLock { current in
            let replay = ring.drain(lastMs: lastMs)
            var replayedMs = 0.0
            for buffer in replay {
                request.append(buffer)
                if buffer.format.sampleRate > 0 {
                    replayedMs += Double(buffer.frameLength) / buffer.format.sampleRate * 1000.0
                }
            }
            let previous = current
            current = request
            return (previous, replay.count, Int(replayedMs))
        }
    }

    /// True when the given request is still the active one. Lets a recognition callback ignore
    /// results from a request that a rotation already superseded.
    nonisolated func isCurrent(_ request: SFSpeechAudioBufferRecognitionRequest) -> Bool {
        state.withLock { current in
            current === request
        }
    }

    /// Clears the box and returns whatever was in it.
    @discardableResult
    nonisolated func clear() -> SFSpeechAudioBufferRecognitionRequest? {
        swap(to: nil)
    }
}
