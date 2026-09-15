//
//  ConversationKeychain.swift
//  TranslatorApp
//
//  Where the device key is kept, and the one rule that matters about it (2026-09-15):
//  AN EXISTING KEY IS NEVER REPLACED.
//
//  Every saved conversation is sealed to this key. Creating a new one while an old one exists —
//  because a read failed with the device locked, say — would make every conversation saved so
//  far unreadable forever. So a key is created only when the keychain positively reports that
//  there is none; any other failure is an error, never a reason to start over.
//
//  The item is `ThisDeviceOnly` and not synchronizable: it never travels in a backup or through
//  iCloud Keychain. On a device it holds only the Secure Enclave's opaque blob, which no other
//  device can use.
//

import CryptoKit
import Foundation
import LocalAuthentication
import OSLog
import Security

nonisolated enum ConversationKeychain {

    private nonisolated static var service: String { "com.spanesso.TraslatorApp.conversation-key" }
    private nonisolated static var account: String { "device-key" }

    private nonisolated struct StoredKey: Codable {
        let kind: String
        let key: Data
    }

    nonisolated static func loadOrCreateDeviceKey() throws -> any ConversationDeviceKey {
        if let stored = try readStoredKey() { return try deviceKey(from: stored) }

        let (key, stored) = try makeDeviceKey()
        switch add(stored) {
        case errSecSuccess:
            Logger(subsystem: "com.spanesso.TraslatorApp", category: "Security")
                .notice("[Security] device key created (\(stored.kind, privacy: .public))")
            return key
        case errSecDuplicateItem:
            // Another caller created it first. Theirs is the key; ours is discarded unused.
            guard let existing = try readStoredKey() else { throw ConversationSealingError.keyUnavailable }
            return try deviceKey(from: existing)
        default:
            throw ConversationSealingError.keyUnavailable
        }
    }

    // MARK: - Creation

    /// Secure Enclave with user presence when the device can verify its owner; Secure Enclave
    /// without it when there is no passcode (the conversation must still be savable); software
    /// only where no Secure Enclave exists — the simulator.
    private nonisolated static func makeDeviceKey() throws -> (any ConversationDeviceKey, StoredKey) {
        guard SecureEnclave.isAvailable else {
            let key = SoftwareDeviceKey()
            return (key, StoredKey(kind: "software", key: key.rawRepresentation))
        }
        let ownerCanBeVerified = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
        if ownerCanBeVerified, let key = try? SecureEnclaveDeviceKey.create(requiringUserPresence: true) {
            return (key, StoredKey(kind: "secureEnclave+presence", key: key.dataRepresentation))
        }
        let key = try SecureEnclaveDeviceKey.create(requiringUserPresence: false)
        return (key, StoredKey(kind: "secureEnclave", key: key.dataRepresentation))
    }

    private nonisolated static func deviceKey(from stored: StoredKey) throws -> any ConversationDeviceKey {
        do {
            switch stored.kind {
            case "secureEnclave+presence":
                return try SecureEnclaveDeviceKey(dataRepresentation: stored.key, requiresUserPresence: true)
            case "secureEnclave":
                return try SecureEnclaveDeviceKey(dataRepresentation: stored.key, requiresUserPresence: false)
            case "software":
                return try SoftwareDeviceKey(rawRepresentation: stored.key)
            default:
                throw ConversationSealingError.keyUnavailable
            }
        } catch {
            throw ConversationSealingError.keyUnavailable
        }
    }

    // MARK: - Keychain

    private nonisolated static var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }

    /// nil ONLY when the keychain says the item does not exist.
    private nonisolated static func readStoredKey() throws -> StoredKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data,
                  let stored = try? JSONDecoder().decode(StoredKey.self, from: data) else {
                throw ConversationSealingError.keyUnavailable
            }
            return stored
        case errSecItemNotFound:
            return nil
        default:
            throw ConversationSealingError.keyUnavailable
        }
    }

    private nonisolated static func add(_ stored: StoredKey) -> OSStatus {
        guard let data = try? JSONEncoder().encode(stored) else { return errSecParam }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil)
    }
}
