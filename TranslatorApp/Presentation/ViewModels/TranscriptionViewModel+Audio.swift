//
//  TranscriptionViewModel+Audio.swift
//  TranslatorApp
//
//  The meeting's audio, from the first buffer to the moment it stops existing (2026-09-15).
//  Contract and rationale: Domain/Interfaces/MeetingAudioProtocol.swift.
//
//  THE LIFETIME, IN ONE PLACE
//  It begins with the recording and ends with the user's decision:
//  - start of a recording   → a new file (a restart that keeps the meeting keeps writing to it)
//  - stop                   → the file is closed, still on disk, ready for diarisation
//  - saved, or discarded    → shredded
//  - a new meeting replaces an undecided one → shredded with it
//  - at launch              → every file except the meeting waiting to be recovered is shredded
//
//  Every call is best-effort and silent. Audio is the one thing here that MAY be lost; the
//  transcript is not, so nothing in this file is allowed to fail a meeting or block a save.
//

import SwiftUI
import OSLog

@MainActor
extension TranscriptionViewModel {

    /// Starts writing the audio of the current session. Awaited before the pipeline starts, so the
    /// first words of the meeting are in the file and not only in the transcript.
    func beginMeetingAudio() async {
        await meetingAudio.beginSession(id: sessionId)
    }

    /// Closes the file. Called on every path that ends a recording — the audio of a meeting that
    /// ended in failure is just as useful as the audio of one that ended normally.
    func finishMeetingAudio() async {
        guard let recording = await meetingAudio.finishSession() else { return }
        logger.info("[ViewModel] meeting audio kept: \(recording.durationMs)ms until the user decides")
    }

    /// The meeting's audio has served its purpose — it was saved, shared or discarded.
    func shredMeetingAudio(of sessionId: String) async {
        await meetingAudio.shred(sessionId: sessionId)
    }

    /// At launch: audio left behind by a crash outlives its meeting otherwise. The meeting waiting
    /// to be recovered keeps its own, because the user has not decided about it yet.
    func shredOrphanedAudio(keeping sessionId: String?) async {
        await meetingAudio.shredEverything(except: sessionId)
    }
}
