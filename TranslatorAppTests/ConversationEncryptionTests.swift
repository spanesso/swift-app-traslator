//
//  ConversationEncryptionTests.swift
//  TranslatorAppTests
//
//  A saved conversation is private to its user (2026-09-15): what is on disk must not be readable,
//  by anyone and by the app itself, without the user's device key.
//
//  The software key stands in for the Secure Enclave, which the simulator does not have. The
//  envelope, the store format and the repository are the production code paths.
//

import SwiftData
import XCTest
@testable import TranslatorApp

@MainActor
final class ConversationEncryptionTests: XCTestCase {

    private let english = "the merger closes on friday"
    private let spanish = "la fusión cierra el viernes"

    private func makeStore() throws -> ModelContainer {
        try ModelContainer(for: ConversationRecord.self,
                           configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    }

    private func makeRepository(_ store: ModelContainer,
                                key: SoftwareDeviceKey = SoftwareDeviceKey()) -> ConversationRepository {
        ConversationRepository(context: store.mainContext,
                               sealer: HybridConversationSealer(loadKey: { key }))
    }

    private func storedRecords(_ store: ModelContainer) throws -> [ConversationRecord] {
        try store.mainContext.fetch(FetchDescriptor<ConversationRecord>())
    }

    // MARK: - Nothing readable on disk

    /// THE PROMISE. Nothing of what was said may appear in the stored record.
    func testSavedConversationIsNotReadableInTheStore() async throws {
        let store = try makeStore()
        let repository = makeRepository(store)

        try await repository.save(ConversationEntity(id: UUID(), englishText: english,
                                                     spanishText: spanish, savedAt: Date()))

        let records = try storedRecords(store)
        XCTAssertEqual(records.count, 1)
        let stored = records[0].englishText + records[0].spanishText
        XCTAssertFalse(stored.contains("merger"), "the English text is stored in the clear")
        XCTAssertFalse(stored.contains("fusión"), "the Spanish text is stored in the clear")
    }

    /// The history lists conversations without decrypting — and without revealing content.
    func testListingRevealsOnlyWhenEachConversationWasSaved() async throws {
        let store = try makeStore()
        let repository = makeRepository(store)
        let savedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let id = UUID()
        try await repository.save(ConversationEntity(id: id, englishText: english,
                                                     spanishText: spanish, savedAt: savedAt))

        let summaries = try await repository.fetchSummaries()
        XCTAssertEqual(summaries, [ConversationSummary(id: id, savedAt: savedAt)])
    }

    // MARK: - Only the device key opens it

    func testTheDeviceKeyOpensTheWholeConversation() async throws {
        let store = try makeStore()
        let repository = makeRepository(store)
        let id = UUID()
        try await repository.save(ConversationEntity(id: id, englishText: english,
                                                     spanishText: spanish, savedAt: Date()))

        let opened = try await repository.open(id: id, reason: "test")
        XCTAssertEqual(opened.englishText, english)
        XCTAssertEqual(opened.spanishText, spanish)
    }

    func testAnotherKeyCannotOpenIt() async throws {
        let store = try makeStore()
        let id = UUID()
        try await makeRepository(store).save(ConversationEntity(id: id, englishText: english,
                                                                spanishText: spanish, savedAt: Date()))

        do {
            _ = try await makeRepository(store, key: SoftwareDeviceKey()).open(id: id, reason: "test")
            XCTFail("a conversation opened with a key it was not sealed to")
        } catch {
            XCTAssertEqual(error as? ConversationSealingError, .unreadable)
        }
    }

    func testAlteredConversationIsRejected() async throws {
        let store = try makeStore()
        let key = SoftwareDeviceKey()
        let repository = makeRepository(store, key: key)
        let id = UUID()
        try await repository.save(ConversationEntity(id: id, englishText: english,
                                                     spanishText: spanish, savedAt: Date()))

        let record = try XCTUnwrap(try storedRecords(store).first)
        let marker = ConversationRepository.sealedMarker
        var envelope = try XCTUnwrap(Data(base64Encoded: String(record.englishText.dropFirst(marker.count))))
        envelope[envelope.count - 1] ^= 0x01
        record.englishText = marker + envelope.base64EncodedString()

        do {
            _ = try await repository.open(id: id, reason: "test")
            XCTFail("an altered conversation was accepted")
        } catch {
            XCTAssertEqual(error as? ConversationSealingError, .unreadable)
        }
    }

    // MARK: - Store unavailable at launch

    /// With an in-memory stand-in, a "successful" save would vanish at exit. It must fail loudly,
    /// so the meeting and its journal are kept.
    func testSavingToAStandInStoreFails() async throws {
        let store = try makeStore()
        let repository = ConversationRepository(context: store.mainContext,
                                                sealer: HybridConversationSealer(loadKey: { SoftwareDeviceKey() }),
                                                isPersistent: false)
        do {
            try await repository.save(ConversationEntity(id: UUID(), englishText: english,
                                                         spanishText: spanish, savedAt: Date()))
            XCTFail("a save to a store that will not survive the app reported success")
        } catch {
            XCTAssertEqual(error as? ConversationStoreError, .storeUnavailable)
        }
    }

    // MARK: - Conversations saved by earlier versions

    func testConversationsStoredInClearAreSealed() async throws {
        let store = try makeStore()
        let repository = makeRepository(store)
        let id = UUID()
        store.mainContext.insert(ConversationRecord(id: id, englishText: english,
                                                    spanishText: spanish, savedAt: Date()))
        try store.mainContext.save()

        let sealed = try await repository.sealLegacyConversations()
        XCTAssertEqual(sealed, 1)

        let record = try XCTUnwrap(try storedRecords(store).first)
        XCTAssertFalse((record.englishText + record.spanishText).contains("merger"))
        let opened = try await repository.open(id: id, reason: "test")
        XCTAssertEqual(opened.englishText, english, "sealing an old conversation must not change it")
        XCTAssertEqual(opened.spanishText, spanish)

        let again = try await repository.sealLegacyConversations()
        XCTAssertEqual(again, 0, "an already sealed conversation is never sealed twice")
    }
}
