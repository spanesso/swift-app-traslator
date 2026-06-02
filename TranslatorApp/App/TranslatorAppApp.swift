//
//  TranslatorAppApp.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 9/02/26.
//

import SwiftUI
import SwiftData

@main
struct TranslatorAppApp: App {
    // DependencyContainer owns the full object graph including all cached ViewModels.
    // Using @State ensures it is created exactly once for the app session.
    @State private var container = DependencyContainer()

    var body: some Scene {
        WindowGroup {
            LiveTranscriptionView(
                viewModel: container.makeTranscriptionViewModel(),
                historyViewModel: container.makeHistoryViewModel()
            )
        }
        // Register the SwiftData container so any view in the hierarchy can
        // use @Environment(\.modelContext) if needed in the future.
        .modelContainer(container.modelContainer)
    }
}
