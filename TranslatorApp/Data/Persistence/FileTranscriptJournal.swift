//
//  FileTranscriptJournal.swift
//  TranslatorApp
//
//  Append-only, crash-safe journal of the meeting in progress
//  (010-transcript-durability, US1 and US2).
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

import Foundation
import OSLog

actor FileTranscriptJournal: TranscriptJournalProtocol {

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "Journal")
    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var handle: FileHandle?
    private var currentSessionId: String?

    private nonisolated static var directoryName: String { "LiveTranscript" }
    private nonisolated static var fileName: String { "session.jsonl" }

    // MARK: - Location

    private func journalURL() throws -> URL {
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
        // A journal can legitimately not be open yet — a recovered session being re-displayed,
        // for instance. Opening lazily keeps the caller from having to know.
        if handle == nil {
            try beginSessionIfNeeded(id: entry.sessionId)
        }
        guard let handle else { throw TranscriptJournalError.storageUnavailable }

        do {
            var line = try encoder.encode(entry)
            line.append(0x0A) // newline: the delimiter the whole recovery story depends on
            try handle.write(contentsOf: line)
            // Flush to disk NOW. Without this the guarantee is "the text survives if the app
            // exits politely", which is precisely the case that was never the problem.
            try handle.synchronize()
        } catch {
            logger.error("[Journal] write failed: \(error.localizedDescription, privacy: .public)")
            throw TranscriptJournalError.writeFailed(error.localizedDescription)
        }
    }

    private func beginSessionIfNeeded(id: String) throws {
        let url = try journalURL()
        if !fileManager.fileExists(atPath: url.path) {
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

    // MARK: - Recovery

    func hasPendingSession() -> Bool {
        guard let url = try? journalURL(),
              let size = try? fileManager.attributesOfItem(atPath: url.path)[.size] as? Int else {
            return false
        }
        return size > 0
    }

    func pendingSession() -> RecoveredSession? {
        guard let url = try? journalURL(),
              let data = try? Data(contentsOf: url),
              !data.isEmpty else { return nil }

        var sources: [Int: (text: String, confidence: Float)] = [:]
        var outcomes: [Int: TranslationOutcome] = [:]
        var sessionId: String?
        var earliestEpochMs = Int.max
        var damagedLines = 0

        // Split on newlines and decode each line independently. A line that does not decode is
        // the torn tail of a killed write — dropping it costs one phrase and saves the rest.
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let entry = try? decoder.decode(TranscriptJournalEntry.self, from: Data(line)) else {
                damagedLines += 1
                continue
            }
            sessionId = sessionId ?? entry.sessionId
            earliestEpochMs = min(earliestEpochMs, entry.epochMs)
            switch entry.kind {
            case .source:
                if let text = entry.sourceText {
                    sources[entry.fragmentId] = (text, entry.confidence ?? 1.0)
                }
            case .translation:
                if let outcome = entry.replayedOutcome { outcomes[entry.fragmentId] = outcome }
            }
        }

        if damagedLines > 0 {
            logger.warning("[Journal] discarded \(damagedLines) damaged entr\(damagedLines == 1 ? "y" : "ies")")
        }
        guard !sources.isEmpty, let sessionId else { return nil }

        // Ordered by fragment id, not by position in the file: entries may have been appended
        // out of order and it does not matter.
        let fragments = sources.keys.sorted().map { id -> ConversationFragment in
            let source = sources[id]!
            return ConversationFragment(id: id,
                                        sourceText: source.text,
                                        translation: outcomes[id] ?? .unavailable(.timedOut),
                                        sourceConfidence: source.confidence)
        }
        logger.info("[Journal] recovered \(fragments.count) fragment(s) from session \(sessionId, privacy: .public)")
        return RecoveredSession(sessionId: sessionId,
                                fragments: fragments,
                                startedAtEpochMs: earliestEpochMs == .max ? 0 : earliestEpochMs)
    }

    func discard() {
        closeHandle()
        if let url = try? journalURL() {
            try? fileManager.removeItem(at: url)
        }
        currentSessionId = nil
        logger.info("[Journal] discarded")
    }

    private func closeHandle() {
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
