//
//  PipelineTelemetry+Audio.swift
//  TranslatorApp
//
//  Recording of the meeting's audio (2026-09-15).
//

import Foundation

extension PipelineTelemetryProtocol {

    /// The meeting's audio file: `started`, `stopped`, `shredded`, `orphans-shredded`, `empty`,
    /// `missing`, `no-space`, `failed`, `unavailable`. Sizes and durations only — never audio,
    /// never text.
    ///
    /// ```
    /// grep '\[MEETING_AUDIO\]' | grep 'state=stopped'   # dropped=0 means nothing was lost
    /// grep '\[MEETING_AUDIO\]' | grep -v 'state=st'     # every meeting that recorded no audio
    /// ```
    nonisolated func meetingAudio(_ sid: String, state: String, durationMs: Int, kb: Int, dropped: Int) {
        emit(TelemetryEvent(kind: .meetingAudio, sessionId: sid, fields: [
            .init("state", state), .init("durMs", durationMs), .init("kb", kb), .init("dropped", dropped)
        ]))
    }
}
