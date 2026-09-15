//
//  HybridConversationSealer.swift
//  TranslatorApp
//
//  Seals and opens whole conversations with the device key (2026-09-15).
//  The key is loaded on first use and kept; a failed load is retried on the next call rather than
//  remembered, so a keychain that was momentarily unavailable does not block saving for good.
//

import Foundation
import os

nonisolated final class HybridConversationSealer: ConversationSealingProtocol {

    private let loadKey: @Sendable () throws -> any ConversationDeviceKey
    private let cachedKey = OSAllocatedUnfairLock<(any ConversationDeviceKey)?>(initialState: nil)

    nonisolated init(loadKey: @escaping @Sendable () throws -> any ConversationDeviceKey) {
        self.loadKey = loadKey
    }

    nonisolated func seal(_ plaintext: Data) throws -> Data {
        try ConversationEnvelope.seal(plaintext, toPublicKey: deviceKey().publicKeyData)
    }

    nonisolated func open(_ sealed: Data, reason: String) async throws -> Data {
        try await ConversationEnvelope.open(sealed, with: deviceKey(), reason: reason)
    }

    private nonisolated func deviceKey() throws -> any ConversationDeviceKey {
        if let key = cachedKey.withLock({ $0 }) { return key }
        let key = try loadKey()
        cachedKey.withLock { $0 = key }
        return key
    }
}
