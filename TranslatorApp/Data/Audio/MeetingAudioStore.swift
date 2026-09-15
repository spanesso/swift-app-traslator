//
//  MeetingAudioStore.swift
//  TranslatorApp
//
//  Where the meeting's audio lives, and when it stops existing (2026-09-15).
//  Contract and rationale: Domain/Interfaces/MeetingAudioProtocol.swift.
//
//  One file per meeting, named after its session, next to the transcript journal:
//  Application Support/LiveTranscript/audio/meeting-<session>.caf
//
//  PROTECTED WHILE IT EXISTS, GONE WHEN THE USER DECIDES
//  `.completeUntilFirstUserAuthentication` — the journal's class, and for the same reason: recording
//  continues with the screen locked (008 decision Q3), and the default class would refuse the write.
//  Excluded from backups, so it is never uploaded anywhere automatically. Deleted when the user
//  saves, shares or discards the meeting, and at launch if a crash left one behind.
//
//  "SHRED" IS AN HONEST DELETE. The file is removed, not overwritten: on flash storage overwriting
//  guarantees nothing about the old blocks. What makes the bytes unreadable to anyone else is the
//  protection class, which ties them to this device being unlocked — not a pass of zeroes.
//
//  NOTHING HERE FAILS A MEETING. No disk, no space, no writable file: the meeting is recorded
//  without audio and the reason is in the telemetry.
//

import AVFoundation
import Foundation
import OSLog

actor MeetingAudioStore: MeetingAudioProtocol {

    /// Recording audio needs room to run. Below this the meeting goes ahead without it rather than
    /// filling the disk the transcript also has to be written to.
    nonisolated static var minimumFreeBytes: Int64 { 500 * 1024 * 1024 }
    private nonisolated static var directoryName: String { "audio" }
    private nonisolated static var journalDirectoryName: String { "LiveTranscript" }

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "MeetingAudio")
    private let telemetry: any PipelineTelemetryProtocol
    private let sink: AudioBufferSink
    private let fileManager = FileManager.default
    private let writer = MeetingAudioWriter()

    private var openSessionId: String?

    init(sink: AudioBufferSink, telemetry: any PipelineTelemetryProtocol) {
        self.sink = sink
        self.telemetry = telemetry
    }

    // MARK: - Recording

    func beginSession(id: String) async {
        if openSessionId != nil { _ = await finishSession() }

        guard let url = audioURL(for: id) else {
            telemetry.meetingAudio(id, state: "unavailable", durationMs: 0, kb: 0, dropped: 0)
            return
        }
        // A file of the same session left by an earlier attempt is replaced, not appended to.
        try? fileManager.removeItem(at: url)

        guard hasRoomToRecord(at: url) else {
            telemetry.meetingAudio(id, state: "no-space", durationMs: 0, kb: 0, dropped: 0)
            logger.error("[MeetingAudio] not enough free space; recording without audio")
            return
        }

        do {
            try writer.open(url: url)
        } catch {
            telemetry.meetingAudio(id, state: "failed", durationMs: 0, kb: 0, dropped: 0)
            logger.error("[MeetingAudio] could not open the audio file: \(error.localizedDescription, privacy: .public)")
            return
        }
        // Belt and braces: the directory's class is inherited by new files, and this states it on
        // the file itself, because the recording depends on it while the screen is locked.
        try? fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)

        openSessionId = id
        sink.add(writer)
        telemetry.meetingAudio(id, state: "started", durationMs: 0, kb: 0, dropped: 0)
        logger.info("[MeetingAudio] recording audio of session \(id, privacy: .public)")
    }

    func finishSession() async -> MeetingAudioRecording? {
        guard let id = openSessionId else { return nil }
        openSessionId = nil
        // Detach BEFORE closing: the writer must not be handed a buffer while its file is going away.
        sink.remove(writer)
        let stats = writer.close()

        guard let url = audioURL(for: id), fileManager.fileExists(atPath: url.path) else {
            telemetry.meetingAudio(id, state: "missing", durationMs: 0, kb: 0, dropped: stats.droppedBuffers)
            return nil
        }
        let bytes = fileSize(at: url)
        guard stats.framesWritten > 0 else {
            // Nothing was captured: an empty file is only a privacy liability.
            try? fileManager.removeItem(at: url)
            telemetry.meetingAudio(id, state: "empty", durationMs: 0, kb: 0, dropped: stats.droppedBuffers)
            return nil
        }
        telemetry.meetingAudio(id, state: "stopped",
                               durationMs: stats.durationMs,
                               kb: bytes / 1024,
                               dropped: stats.droppedBuffers)
        if stats.droppedBuffers > 0 || stats.writeFailures > 0 {
            logger.warning("""
                [MeetingAudio] session \(id, privacy: .public) dropped \(stats.droppedBuffers) \
                buffer(s), \(stats.writeFailures) write failure(s)
                """)
        }
        logger.info("[MeetingAudio] audio of \(id, privacy: .public) closed: \(stats.durationMs)ms, \(bytes / 1024)KB")
        return MeetingAudioRecording(sessionId: id, url: url, durationMs: stats.durationMs, bytes: bytes)
    }

    func recording(for sessionId: String) async -> MeetingAudioRecording? {
        guard let url = audioURL(for: sessionId), fileManager.fileExists(atPath: url.path) else { return nil }
        let bytes = fileSize(at: url)
        guard bytes > 0 else { return nil }
        // Duration from the file itself, so this is right for a file a crash cut short.
        let durationMs = (try? AVAudioFile(forReading: url)).map {
            Int(Double($0.length) / $0.fileFormat.sampleRate * 1000.0)
        } ?? 0
        return MeetingAudioRecording(sessionId: sessionId, url: url, durationMs: durationMs, bytes: bytes)
    }

    // MARK: - Shredding

    func shred(sessionId: String) async {
        if openSessionId == sessionId { _ = await finishSession() }
        guard let url = audioURL(for: sessionId), fileManager.fileExists(atPath: url.path) else { return }
        do {
            try fileManager.removeItem(at: url)
            telemetry.meetingAudio(sessionId, state: "shredded", durationMs: 0, kb: 0, dropped: 0)
            logger.info("[MeetingAudio] audio of \(sessionId, privacy: .public) shredded")
        } catch {
            logger.error("[MeetingAudio] could not shred audio: \(error.localizedDescription, privacy: .public)")
        }
    }

    func shredEverything(except sessionId: String?) async {
        guard let directory = audioDirectory(create: false) else { return }
        guard let files = try? fileManager.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil) else { return }
        let kept = sessionId.flatMap { audioURL(for: $0)?.lastPathComponent }
        var removed = 0
        for file in files where file.lastPathComponent != kept {
            // Never touch the file being written right now.
            if let openSessionId, file.lastPathComponent == audioURL(for: openSessionId)?.lastPathComponent {
                continue
            }
            if (try? fileManager.removeItem(at: file)) != nil { removed += 1 }
        }
        if removed > 0 {
            telemetry.meetingAudio(sessionId ?? "----", state: "orphans-shredded",
                                   durationMs: 0, kb: 0, dropped: removed)
            logger.notice("[MeetingAudio] \(removed) orphaned audio file(s) shredded")
        }
    }

    // MARK: - Location

    private func audioDirectory(create: Bool) -> URL? {
        guard let support = try? fileManager.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: create) else { return nil }
        let directory = support
            .appendingPathComponent(Self.journalDirectoryName, isDirectory: true)
            .appendingPathComponent(Self.directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            guard create else { return nil }
            do {
                try fileManager.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            } catch {
                logger.error("[MeetingAudio] could not create the audio directory: \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        // The meeting's audio must never ride along in an automatic backup.
        BackupExclusion.exclude(directory)
        return directory
    }

    private func audioURL(for sessionId: String) -> URL? {
        guard let directory = audioDirectory(create: true) else { return nil }
        // Session ids come from `TelemetrySessionId`: four characters, letters and digits. Anything
        // else would be a path, so it is refused rather than sanitised.
        guard !sessionId.isEmpty, sessionId.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else {
            return nil
        }
        return directory.appendingPathComponent("meeting-\(sessionId).caf")
    }

    private func hasRoomToRecord(at url: URL) -> Bool {
        let values = try? url.deletingLastPathComponent().resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let available = values?.volumeAvailableCapacityForImportantUsage else { return true }
        return available >= Self.minimumFreeBytes
    }

    private func fileSize(at url: URL) -> Int {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int).flatMap { $0 } ?? 0
    }
}
