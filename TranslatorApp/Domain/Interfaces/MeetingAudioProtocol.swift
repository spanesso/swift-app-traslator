//
//  MeetingAudioProtocol.swift
//  TranslatorApp
//
//  The meeting's audio while it is being recorded (2026-09-15).
//  Implementation: Data/Audio/MeetingAudioStore.swift — gate G1.
//
//  WHY THE APP KEEPS THE AUDIO AT ALL
//  Telling the speakers apart needs the audio, and so does measuring how much of the conversation
//  the recogniser actually got. Neither can be done from text alone.
//
//  WHY IT IS A WORKING FILE AND NOT PART OF THE ARCHIVE
//  It lives from the start of the recording until the user decides — save, share or discard — and is
//  then shredded. A saved conversation keeps its text and nothing else. The reasons are privacy and
//  honesty: keeping the raw audio of every meeting would double what a stolen device gives up, for a
//  benefit the user never sees, and it costs ~115 MB per hour. Anything that needs the audio (the
//  diarisation that names the speakers) runs before the user decides, while the file is still there.
//
//  WHILE IT EXISTS it is protected like the journal — `.completeUntilFirstUserAuthentication`, and
//  excluded from backups, so it is never uploaded anywhere automatically.
//
//  AUDIO NEVER ENDANGERS THE TRANSCRIPT. Every operation here is best-effort and reports through
//  telemetry: a full disk, a file that will not open, a write that fails. None of it throws into the
//  recording path, because the text is the thing that may not be lost — the audio is not.
//

import Foundation

/// One meeting's recorded audio on disk.
nonisolated struct MeetingAudioRecording: Sendable, Equatable {
    let sessionId: String
    let url: URL
    /// Audio actually written, in milliseconds. 0 when nothing was captured.
    let durationMs: Int
    let bytes: Int

    nonisolated init(sessionId: String, url: URL, durationMs: Int, bytes: Int) {
        self.sessionId = sessionId
        self.url = url
        self.durationMs = durationMs
        self.bytes = bytes
    }
}

protocol MeetingAudioProtocol: Sendable {

    /// Starts recording the audio of `id` alongside the transcript. Never throws: if the audio
    /// cannot be recorded the meeting goes on without it.
    func beginSession(id: String) async

    /// Closes the file and returns what was written, or nil if nothing was.
    func finishSession() async -> MeetingAudioRecording?

    /// The audio of a meeting already finished, for whatever needs to read it.
    func recording(for sessionId: String) async -> MeetingAudioRecording?

    /// Deletes one meeting's audio. Called when the user saves, shares or discards it.
    func shred(sessionId: String) async

    /// Deletes every meeting's audio except `sessionId` — the one still waiting for the user to
    /// decide. Called at launch, so audio left behind by a crash does not outlive its meeting.
    func shredEverything(except sessionId: String?) async
}
