//
//  ConversationDeviceKey.swift
//  TranslatorApp
//
//  The key saved conversations are sealed to (2026-09-15).
//
//  On a real device it lives in the Secure Enclave: its private half never exists outside the
//  chip, cannot be copied to another device or a backup, and — when the device has a passcode —
//  can only be used after Face ID, Touch ID or the passcode. The software variant exists for the
//  simulator and for tests, where there is no Secure Enclave.
//

import CryptoKit
import Foundation
import LocalAuthentication

protocol ConversationDeviceKey: Sendable {
    /// X9.63 public key. Enough to SEAL; useless to open.
    nonisolated var publicKeyData: Data { get }
    /// Whether opening asks for the user.
    nonisolated var requiresUserPresence: Bool { get }
    /// The ECDH secret with an envelope's ephemeral key. This is the step that needs the user.
    nonisolated func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, reason: String) async throws -> Data
}

// MARK: - Secure Enclave

nonisolated struct SecureEnclaveDeviceKey: ConversationDeviceKey {

    /// An opaque blob only THIS device's Secure Enclave can use. Not the key itself.
    let dataRepresentation: Data
    let publicKeyData: Data
    let requiresUserPresence: Bool

    nonisolated init(dataRepresentation: Data, requiresUserPresence: Bool) throws {
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: dataRepresentation)
        self.dataRepresentation = dataRepresentation
        self.publicKeyData = key.publicKey.x963Representation
        self.requiresUserPresence = requiresUserPresence
    }

    nonisolated static func create(requiringUserPresence: Bool) throws -> SecureEnclaveDeviceKey {
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requiringUserPresence { flags.insert(.userPresence) }
        guard let access = SecAccessControlCreateWithFlags(nil,
                                                           kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                                                           flags,
                                                           nil) else {
            throw ConversationSealingError.keyUnavailable
        }
        let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        return try SecureEnclaveDeviceKey(dataRepresentation: key.dataRepresentation,
                                          requiresUserPresence: requiringUserPresence)
    }

    nonisolated func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, reason: String) async throws -> Data {
        let context = LAContext()
        if requiresUserPresence {
            do {
                _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            } catch let error as LAError {
                switch error.code {
                case .userCancel, .appCancel, .systemCancel: throw ConversationSealingError.cancelled
                default:                                     throw ConversationSealingError.authenticationFailed
                }
            } catch {
                throw ConversationSealingError.authenticationFailed
            }
        }
        do {
            // The evaluated context is handed over, so the enclave does not prompt a second time.
            let key = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: dataRepresentation,
                                                                     authenticationContext: context)
            return try key.sharedSecretFromKeyAgreement(with: ephemeral).withUnsafeBytes { Data($0) }
        } catch {
            throw ConversationSealingError.authenticationFailed
        }
    }
}

// MARK: - Software (simulator and tests)

nonisolated struct SoftwareDeviceKey: ConversationDeviceKey {

    let rawRepresentation: Data
    let publicKeyData: Data
    var requiresUserPresence: Bool { false }

    nonisolated init() {
        let key = P256.KeyAgreement.PrivateKey()
        rawRepresentation = key.rawRepresentation
        publicKeyData = key.publicKey.x963Representation
    }

    nonisolated init(rawRepresentation: Data) throws {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
        self.rawRepresentation = rawRepresentation
        publicKeyData = key.publicKey.x963Representation
    }

    nonisolated func sharedSecret(with ephemeral: P256.KeyAgreement.PublicKey, reason: String) async throws -> Data {
        let key = try P256.KeyAgreement.PrivateKey(rawRepresentation: rawRepresentation)
        return try key.sharedSecretFromKeyAgreement(with: ephemeral).withUnsafeBytes { Data($0) }
    }
}
