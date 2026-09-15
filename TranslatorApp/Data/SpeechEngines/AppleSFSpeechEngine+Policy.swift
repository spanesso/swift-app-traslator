//
//  AppleSFSpeechEngine+Policy.swift
//  TranslatorApp
//
//  How requests are built and how much audio a rotation replays (research 2026-09-15).
//  Pure static functions, split from AppleSFSpeechEngine.swift so they are testable without a
//  recogniser and both files stay under the 250-line convention.
//

import Speech

extension AppleSFSpeechEngine {

    /// Length of the carry-over window. It must cover the deaf timeout: that rotation replays
    /// everything since the last transcript, and a 1.5 s window threw away most of the speech
    /// the recogniser had failed to transcribe (research 2026-09-15, P3).
    nonisolated static var carryOverCapacitySeconds: Double { 6.0 }

    /// Nothing the user says may leave the device — not as a fallback, not "only when there is a
    /// network". This used to be `supportsOnDeviceRecognition`, so a device that reported no
    /// local support silently sent the meeting to Apple's servers (research 2026-09-15, A1).
    nonisolated static func verifyOnDeviceRecognition(supported: Bool) throws {
        guard supported else { throw SpeechEngineError.onDeviceRecognitionUnavailable }
    }

    nonisolated static func makeRequest(vocabulary: [String]) -> SFSpeechAudioBufferRecognitionRequest {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        if !vocabulary.isEmpty { request.contextualStrings = vocabulary }
        // Unconditional. See `verifyOnDeviceRecognition`.
        request.requiresOnDeviceRecognition = true
        return request
    }

    /// How much recent audio a new request is given.
    ///
    /// A deaf rotation replays everything since the last transcript (plus a margin): that is the
    /// speech the old request heard and never transcribed, and a fixed 1.5 s window threw most
    /// of it away (P3). Every other rotation only needs to cover the swap itself — replaying more
    /// would show already-committed words again.
    nonisolated static func replayWindowMs(trigger: RestartTrigger, msSinceLastTranscript: Int) -> Int {
        switch trigger {
        case .deaf: return max(msSinceLastTranscript, 0) + 500
        default:    return 1_500
        }
    }
}

/// What a rotation replayed into the new request. Reported in `RESTART_END`, where it used to be
/// hardcoded to zero.
nonisolated struct CarryOver: Sendable {
    let buffers: Int
    let ms: Int
}
