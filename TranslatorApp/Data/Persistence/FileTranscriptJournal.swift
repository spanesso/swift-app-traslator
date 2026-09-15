//
//  FileTranscriptJournal.swift
//  TranslatorApp
//
//  Append-only, crash-safe journal of the meeting in progress
//  (010-transcript-durability, US1 and US2). Recovery lives in FileTranscriptJournal+Recovery.swift.
//
//  WHY A FILE AND NOT THE DATABASE
//  Crash semantics have to be reasoned about, not hoped for. One JSON object per line, appended
//  and flushed to disk immediately, gives a property that is easy to state and easy to test: a
//  process killed at any instant can only damage the LAST line. Everything before it is whole
//  and parseable. Reproducing that guarantee through an object graph with deferred saves would
//  be considerably harder to argue and to verify.
//
//  It also costs O(1) per phrase regardless of meeting length (SC-007), and needs no schema
//  migration — feature 008 decision Q2 stands untouched.
//
//  FILE PROTECTION MATTERS HERE
//  Feature 008 decision Q3 means recording continues with the screen locked. The default
//  protection class would refuse writes in that state. `.completeUntilFirstUserAuthentication`
//  keeps the file writable while locked, provided the device was unlocked once since boot —
//  which is the honest limit and is stated in the spec.
//
//  A FAILED WRITE LOSES NOTHING (durability audit 2026-09-15)
//  Every entry is queued before it is written and leaves the queue only once it is on storage. A
//  transient failure — a full disk, an I/O error — keeps it for the next write instead of dropping
//  it, and a write cut short is truncated back so it cannot corrupt the entry after it.
//

import Foundation
import OSLog

actor FileTranscriptJournal: TranscriptJournalProtocol {

    let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Journal")
    let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    private var handle: FileHandle?
    private var currentSessionId: String?
    /// Accepted entries not on storage yet, oldest first.
    private var unwritten: [(sessionId: String, line: Data)] = []
    /// Meetings already saved or discarded. A late entry of one of them — a translation arriving
    /// after its journal was deleted — used to recreate the file as a ghost that then blocked the
    /// next meeting from opening its own.
    private var closedSessionIds: Set<String> = []

    private nonisolated static var directoryName: String { "LiveTranscript" }
    private nonisolated static var fileName: String { "session.jsonl" }

    // MARK: - Location

    func journalURL() throws -> URL {
        guard let support = try? fileManager.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: true) else {
            throw TranscriptJournalError.storageUnavailable
        }
        let directory = support.appendingPathComponent(Self.directoryName, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            do {
                try fileManager.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.protectionKey:
                                                    FileProtectionType.completeUntilFirstUserAuthentication])
            } catch {
                throw TranscriptJournalError.storageUnavailable
            }
        }
        // The meeting in progress must never ride along in an automatic backup.
        BackupExclusion.exclude(directory)
        return directory.appendingPathComponent(Self.fileName)
    }

    // MARK: - Session lifecycle

    func beginSession(id: String) throws {
        closeHandle()
        let url = try journalURL()

        // A journal left behind by a previous run is never silently overwritten: the caller is
        // responsible for archiving or discarding it first (FR-017, FR-022).
        if fileManager.fileExists(atPath: url.path) {
            logger.warning("[Journal] a previous journal is still present; refusing to overwrite")
            throw TranscriptJournalError.writeFailed("a previous session is still pending")
        }

        guard fileManager.createFile(
            atPath: url.path,
            contents: nil,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        ) else {
            throw TranscriptJournalError.storageUnavailable
        }

        do {
            handle = try FileHandle(forWritingTo: url)
        } catch {
            throw TranscriptJournalError.writeFailed(error.localizedDescription)
        }
        currentSessionId = id
        logger.info("[Journal] session \(id, privacy: .public) opened")
    }

    func record(_ entry: TranscriptJournalEntry) throws {
        guard !closedSessionIds.contains(entry.sessionId) else { return }

        var line: Data
        do {
            line = try encoder.encode(entry)
        } catch {
            throw TranscriptJournalError.writeFailed(error.localizedDescription)
        }
        line.append(0x0A) // newline: the delimiter the whole recovery story depends on
        // Queued BEFORE anything can fail: from here on the entry is only dropped once written.
        unwritten.append((entry.sessionId, line))

        // A journal can legitimately not be open yet — a recovered session being re-displayed,
        // for instance. Opening lazily keeps the caller from having to know.
        if handle == nil || currentSessionId != entry.sessionId {
            closeHandle()
            try beginSessionIfNeeded(id: entry.sessionId)
        }
        try writeUnwritten()
    }

    /// Writes every queued entry of the open session, in order. Entries of another session stay
    /// queued for when their own journal is open.
    private func writeUnwritten() throws {
        guard let handle, let currentSessionId else { throw TranscriptJournalError.storageUnavailable }
        var kept: [(sessionId: String, line: Data)] = []
        var index = 0
        while index < unwritten.count {
            let item = unwritten[index]
            index += 1
            guard !closedSessionIds.contains(item.sessionId) else { continue }
            guard item.sessionId == currentSessionId else { kept.append(item); continue }

            let offset = try? handle.offset()
            do {
                try handle.write(contentsOf: item.line)
                try Self.commitToStorage(handle)
            } catch {
                // A write cut short leaves half a line, and the next good write would be glued to
                // it and lost with it. Cut the file back to the last whole entry.
                if let offset { try? handle.truncate(atOffset: offset) }
                unwritten = kept + [item] + unwritten[index...]
                logger.error("[Journal] write failed, \(self.unwritten.count) entr(ies) kept for retry: \(error.localizedDescription, privacy: .public)")
                throw TranscriptJournalError.writeFailed(error.localizedDescription)
            }
        }
        unwritten = kept
    }

    /// `F_FULLFSYNC` asks the storage itself to commit, not only the kernel: the difference between
    /// surviving a killed process and surviving a sudden power loss. Falls back to `fsync`.
    private nonisolated static func commitToStorage(_ handle: FileHandle) throws {
        if fcntl(handle.fileDescriptor, F_FULLFSYNC) != 0 {
            try handle.synchronize()
        }
    }

    private func beginSessionIfNeeded(id: String) throws {
        let url = try journalURL()
        if fileManager.fileExists(atPath: url.path) {
            // Never append one meeting to another meeting's journal. When a new session could not
            // open its own journal, every phrase used to land here, in the file of the meeting
            // waiting to be recovered — and recovery then mixed the two (research 2026-09-15, P9).
            if let owner = ownerOfJournal(at: url), owner != id {
                logger.warning("[Journal] refusing to append session \(id, privacy: .public) to the pending journal of \(owner, privacy: .public)")
                throw TranscriptJournalError.writeFailed("another meeting is still waiting to be recovered")
            }
        } else {
            guard fileManager.createFile(
                atPath: url.path,
                contents: nil,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            ) else {
                throw TranscriptJournalError.storageUnavailable
            }
        }
        do {
            let opened = try FileHandle(forWritingTo: url)
            try opened.seekToEnd()
            handle = opened
            currentSessionId = id
        } catch {
            throw TranscriptJournalError.writeFailed(error.localizedDescription)
        }
    }

    /// The session of the first whole entry, or nil when the file holds none.
    private func ownerOfJournal(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            if let entry = try? decoder.decode(TranscriptJournalEntry.self, from: Data(line)) {
                return entry.sessionId
            }
        }
        return nil
    }

    // MARK: - Ending

    func discard() {
        let url = try? journalURL()
        var owner = currentSessionId
        if owner == nil, let url { owner = ownerOfJournal(at: url) }
        if let owner { closedSessionIds.insert(owner) }

        closeHandle()
        if let url { try? fileManager.removeItem(at: url) }
        unwritten.removeAll { closedSessionIds.contains($0.sessionId) }
        currentSessionId = nil
        logger.info("[Journal] discarded")
    }

    func setAsideUnreadable() {
        closeHandle()
        currentSessionId = nil
        guard let url = try? journalURL(), fileManager.fileExists(atPath: url.path) else { return }
        let folder = url.deletingLastPathComponent().appendingPathComponent("Unreadable", isDirectory: true)
        try? fileManager.createDirectory(at: folder,
                                         withIntermediateDirectories: true,
                                         attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        let target = folder.appendingPathComponent("session-\(Int(Date().timeIntervalSince1970)).jsonl")
        do {
            try fileManager.moveItem(at: url, to: target)
            logger.error("[Journal] an unreadable journal was set aside, not deleted")
        } catch {
            logger.error("[Journal] could not set aside an unreadable journal: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func closeHandle() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
