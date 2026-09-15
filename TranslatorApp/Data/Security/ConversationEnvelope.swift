//
//  ConversationEnvelope.swift
//  TranslatorApp
//
//  The on-disk form of a saved conversation (2026-09-15): sealed ONCE, as a whole, to this
//  device's key.
//
//  Hybrid encryption (ECIES): a fresh P-256 key pair per conversation agrees a secret with the
//  device key, HKDF-SHA256 turns it into an AES-256-GCM key, and GCM seals the whole payload.
//  Sealing needs only the device key's PUBLIC half, so saving never waits for the user. Opening
//  needs the PRIVATE half, which the Secure Enclave releases only to the user.
//
//  Layout: [version 1 byte][ephemeral public key, X9.63, 65 bytes][AES-GCM combined box]
//

import CryptoKit
import Foundation

nonisolated enum ConversationEnvelope {

    nonisolated static var version: UInt8 { 1 }
    nonisolated static var ephemeralKeyLength: Int { 65 }
    /// Version, key, 12-byte nonce and 16-byte tag around an empty ciphertext.
    nonisolated static var minimumLength: Int { 1 + ephemeralKeyLength + 12 + 16 }

    nonisolated static func seal(_ plaintext: Data, toPublicKey recipientData: Data) throws -> Data {
        let recipient: P256.KeyAgreement.PublicKey
        do {
            recipient = try P256.KeyAgreement.PublicKey(x963Representation: recipientData)
        } catch {
            throw ConversationSealingError.keyUnavailable
        }
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = derivedKey(secret: secret.withUnsafeBytes { Data($0) },
                             ephemeralKey: ephemeral.publicKey.x963Representation,
                             recipientKey: recipientData)
        guard let box = try AES.GCM.seal(plaintext, using: key).combined else {
            throw ConversationSealingError.unreadable
        }
        var envelope = Data([version])
        envelope.append(ephemeral.publicKey.x963Representation)
        envelope.append(box)
        return envelope
    }

    nonisolated static func open(_ envelope: Data,
                                 with deviceKey: any ConversationDeviceKey,
                                 reason: String) async throws -> Data {
        let bytes = Data(envelope)   // re-based at index 0
        guard bytes.count >= minimumLength, bytes[0] == version else {
            throw ConversationSealingError.unreadable
        }
        let keyEnd = 1 + ephemeralKeyLength
        let ephemeralData = bytes.subdata(in: 1..<keyEnd)
        let ephemeral: P256.KeyAgreement.PublicKey
        do {
            ephemeral = try P256.KeyAgreement.PublicKey(x963Representation: ephemeralData)
        } catch {
            throw ConversationSealingError.unreadable
        }

        let secret = try await deviceKey.sharedSecret(with: ephemeral, reason: reason)
        let key = derivedKey(secret: secret,
                             ephemeralKey: ephemeralData,
                             recipientKey: deviceKey.publicKeyData)
        do {
            let box = try AES.GCM.SealedBox(combined: bytes.subdata(in: keyEnd..<bytes.count))
            return try AES.GCM.open(box, using: key)
        } catch {
            // Another device's key, or altered bytes. GCM cannot tell them apart and neither can we.
            throw ConversationSealingError.unreadable
        }
    }

    /// Both public keys are bound into the derivation, so an envelope cannot be re-targeted.
    private nonisolated static func derivedKey(secret: Data, ephemeralKey: Data, recipientKey: Data) -> SymmetricKey {
        var info = Data("TranslatorApp.conversation.v1".utf8)
        info.append(ephemeralKey)
        info.append(recipientKey)
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: secret),
                                      info: info,
                                      outputByteCount: 32)
    }
}
