//
//  BackupExclusion.swift
//  TranslatorApp
//
//  Keeps the meeting out of device backups (privacy rule of 2026-09-15).
//
//  Nothing of a conversation may leave the app unless the user shares it. An iCloud backup is an
//  automatic upload of the app's container, and Application Support — where the SwiftData store
//  and the live journal live — is included by default. Excluding the directory excludes everything
//  inside it, including files created later.
//
//  Accepted consequence: saved meetings do not survive restoring a device from a backup.
//

import Foundation

enum BackupExclusion {

    /// Marks `url` — and, for a directory, its contents — as excluded from backups.
    @discardableResult
    nonisolated static func exclude(_ url: URL) -> Bool {
        var target = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        do {
            try target.setResourceValues(values)
            return true
        } catch {
            return false
        }
    }

    /// Application Support holds the conversation history and the live journal.
    @discardableResult
    nonisolated static func excludeApplicationSupport() -> Bool {
        guard let support = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                         in: .userDomainMask,
                                                         appropriateFor: nil,
                                                         create: true) else { return false }
        return exclude(support)
    }

    nonisolated static func isExcluded(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup) ?? false
    }
}
