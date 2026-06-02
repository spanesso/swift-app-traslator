//
//  ConversationExport.swift
//  TranslatorApp
//

import CoreTransferable
import UniformTypeIdentifiers
import Foundation

/// Wraps conversation text as a named .txt file for AirDrop and other share destinations.
struct ConversationExport: Transferable {
    let content: String
    let filename: String

    static var transferRepresentation: some TransferRepresentation {
        // FileRepresentation writes the content to a temp file whose name
        // becomes the suggested filename on the receiving device.
        FileRepresentation(exportedContentType: .plainText) { export in
            let url = FileManager.default
                .temporaryDirectory
                .appendingPathComponent(export.filename)
            try export.content.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}
