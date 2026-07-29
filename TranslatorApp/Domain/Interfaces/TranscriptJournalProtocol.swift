//
//  TranscriptJournalProtocol.swift
//  TranslatorApp
//
//  Durable record of the meeting in progress (010-transcript-durability).
//  Implementation: Data/Persistence/FileTranscriptJournal.swift — gate G1.
//
//  The transcript used to live only in a ViewModel array, so a force-quit, a background kill,
//  or one tap on the record button destroyed it. This is the contract that makes the text
//  outlive the process.
//

import Foundation

protocol TranscriptJournalProtocol: Sendable {

    /// Opens a journal for a new meeting. Any previous journal MUST already have been archived
    /// or explicitly discarded — this does not silently overwrite one (FR-017, FR-022).
    func beginSession(id: String) async throws

    /// Persists one entry. Returns only once the entry is durable, so the caller can report a
    /// real failure rather than assume success (FR-001, FR-007).
    func record(_ entry: TranscriptJournalEntry) async throws

    /// Reconstructs a meeting left behind by a previous run, or nil if there is none.
    /// Tolerates a journal cut mid-write: keeps every whole entry, drops only the torn tail
    /// (FR-010).
    func pendingSession() async -> RecoveredSession?

    /// True when a previous run left something recoverable. Cheap enough to call on launch.
    func hasPendingSession() async -> Bool

    /// Deletes the journal. Called ONLY after the meeting is safely archived, or when the user
    /// explicitly discards it (FR-012, FR-017).
    func discard() async
}

/// Why the transcript could not be made durable. Surfaced to the user rather than swallowed:
/// the one thing worse than losing the text is losing it silently.
enum TranscriptJournalError: Error, LocalizedError, Equatable {
    case storageUnavailable
    case writeFailed(String)
    case deviceLocked

    var errorDescription: String? {
        switch self {
        case .storageUnavailable:
            return "The transcript could not be saved: storage is unavailable."
        case .writeFailed(let detail):
            return "The transcript could not be saved: \(detail)"
        case .deviceLocked:
            return "The transcript could not be saved while the device is locked."
        }
    }
}
