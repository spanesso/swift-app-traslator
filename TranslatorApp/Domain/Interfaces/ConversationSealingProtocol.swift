//
//  ConversationSealingProtocol.swift
//  TranslatorApp
//
//  Privacy contract for saved conversations (2026-09-15).
//  Implementation: Data/Security/HybridConversationSealer.swift — gate G1.
//
//  A saved conversation belongs to its user. What is on disk must be unreadable to anyone —
//  including this app — unless that user is present. The whole conversation is sealed ONCE, when
//  the user chooses to save it; the live journal is not sealed phrase by phrase.
//

import Foundation

protocol ConversationSealingProtocol: Sendable {

    /// Encrypts a whole conversation. Never asks the user for anything: saving must not fail for
    /// lack of Face ID, because the conversation is the one thing this app may never lose.
    nonisolated func seal(_ plaintext: Data) throws -> Data

    /// Decrypts a saved conversation. On a device this requires the user — Face ID, Touch ID or
    /// the device passcode — so the app cannot read it on its own.
    nonisolated func open(_ sealed: Data, reason: String) async throws -> Data
}

nonisolated enum ConversationSealingError: Error, LocalizedError, Equatable {
    /// The key conversations are sealed to could not be read or created.
    case keyUnavailable
    /// The data is not a conversation sealed to this device's key, or it was altered.
    case unreadable
    /// The user could not be verified.
    case authenticationFailed
    /// The user dismissed the prompt. Not an error worth reporting.
    case cancelled

    var errorDescription: String? {
        switch self {
        case .keyUnavailable:
            return "The key that protects your conversations is not available on this device."
        case .unreadable:
            return "This conversation could not be decrypted."
        case .authenticationFailed:
            return "Saved conversations can only be opened by the owner of this device."
        case .cancelled:
            return nil
        }
    }
}
