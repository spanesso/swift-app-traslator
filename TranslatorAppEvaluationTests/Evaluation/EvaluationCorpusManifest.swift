//
//  EvaluationCorpusManifest.swift
//  TranslatorAppEvaluationTests
//
//  JSON-decodable corpus manifest. Audio paths are relative to the
//  manifest file's parent directory.
//

import Foundation
@testable import TranslatorApp

struct EvaluationCorpusManifest: Codable, Sendable {
    let name: String
    let license: String
    let items: [Item]

    struct Item: Codable, Sendable {
        let id: String
        let audioPath: String
        let referenceTranscript: String
        let accentGroup: AccentGroup
        let speakerId: String
        let durationSeconds: Double
    }

    // MARK: - Loading

    static func load(from url: URL) throws -> EvaluationCorpusManifest {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(EvaluationCorpusManifest.self, from: data)
    }

    func audioURL(for item: Item, relativeTo manifestURL: URL) -> URL {
        manifestURL.deletingLastPathComponent().appendingPathComponent(item.audioPath)
    }

    var totalAudioSeconds: Double { items.reduce(0) { $0 + $1.durationSeconds } }
    var itemsByAccent: [AccentGroup: [Item]] { Dictionary(grouping: items, by: \.accentGroup) }
}
