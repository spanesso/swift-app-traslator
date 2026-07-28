//
//  AudioRingBuffer.swift (CONTRACT) — feature 006-fix-asr-word-loss
//
//  Carry-over ring buffer that bridges the SFSpeechRecognizer restart gap (finding H1).
//  The tap keeps running across restarts; this buffer holds the most recent ~1.5 s of
//  captured audio so it can be replayed into a freshly-created recognition request,
//  guaranteeing no spoken audio is dropped during the request swap + recognizer warm-up.
//
//  Placement: TranslatorApp/Data/Audio/AudioRingBuffer.swift  (Data layer)
//  Imports: AVFoundation, Foundation only. Actor-local; never touched from MainActor.
//

import AVFoundation
import Foundation

/// Fixed-duration rolling store of recently captured audio buffers, in the tap's native format.
///
/// Contract:
/// - `append(_:)` pushes the latest tap buffer and evicts frames older than `capacitySeconds`.
/// - `drain()` returns buffered frames in chronological order and empties the store; the caller
///   appends them to a new recognition request BEFORE redirecting the live tap and ending the old
///   request. Draining exactly once per restart preserves the no-loss / no-duplicate invariant.
/// - All state is actor-local (or protected by the owning engine actor); buffers are value copies.
protocol AudioRingBuffering: Sendable {
    /// Rolling window length. Must exceed the worst-case restart latency
    /// (150 ms sleep + recognizer warm-up ~0.5–1 s). Default ~1.5 s.
    var capacitySeconds: Double { get }

    /// Push the latest captured buffer (native hardware format). Evicts oldest beyond capacity.
    func append(_ buffer: AVAudioPCMBuffer)

    /// Return buffered frames oldest-first and clear the store. Called once at restart.
    func drain() -> [AVAudioPCMBuffer]

    /// Drop all buffered frames without returning them (e.g. on user stop).
    func reset()
}

// Invariants the implementation MUST uphold:
// 1. No tap buffer is ever appended to a nil or already-ended recognition request.
//    Restart order: build+start new request → append drain() → redirect tap → end old request.
// 2. drain() is called exactly once per restart; carry-over audio is replayed exactly once.
// 3. Buffer format matches the tap's native output format (do NOT pre-resample here;
//    resampling for WhisperKit is a separate concern — see W1 / AVAudioConverter).
// 4. Memory is bounded by capacitySeconds × sampleRate × bytesPerFrame — a small fixed cost.
