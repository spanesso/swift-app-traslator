//
//  TranslatorAppApp.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 9/02/26.
//

import SwiftUI

@main
struct TranslatorAppApp: App {
    @State private var container = DependencyContainer()
    
    var body: some Scene {
        WindowGroup {
            LiveTranscriptionView(
                viewModel: container.makeTranscriptionViewModel()
            )
        }
    }
}
