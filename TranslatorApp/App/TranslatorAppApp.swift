//
//  TranslatorAppApp.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 9/02/26.
//

import SwiftUI
import SwiftData
import UIKit

@main
struct TranslatorAppApp: App {
    // DependencyContainer owns the full object graph including all cached ViewModels.
    // Using @State ensures it is created exactly once for the app session.
    @State private var container = DependencyContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LiveTranscriptionView(
                viewModel: container.makeTranscriptionViewModel(),
                historyViewModel: container.makeHistoryViewModel()
            )
            // 008 (US1 / FR-006): scene-phase transitions are reported so a stretch lost to
            // backgrounding is visible in the log rather than inferred later from a gap in the
            // transcript. Nothing observed this before.
            .onChange(of: scenePhase, initial: false) { _, phase in
                let viewModel = container.makeTranscriptionViewModel()
                container.makeTelemetry().scenePhaseChange(
                    viewModel.sessionId,
                    phase: Self.describe(phase),
                    wasRecording: viewModel.isRecording,
                    engineIsRunning: viewModel.isRecording && !viewModel.isSuspended
                )
                // Leaving the foreground is when the system is most likely to terminate the app:
                // the phrase in progress goes to disk now (2026-09-15).
                if phase != .active { viewModel.handleLeavingForeground() }
            }
            // A memory warning can be the last chance before a termination that runs no code.
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
                container.makeTranscriptionViewModel().handleMemoryWarning()
            }
        }
        // Register the SwiftData container so any view in the hierarchy can
        // use @Environment(\.modelContext) if needed in the future.
        .modelContainer(container.modelContainer)
    }

    private static func describe(_ phase: ScenePhase) -> String {
        switch phase {
        case .active:     return "active"
        case .inactive:   return "inactive"
        case .background: return "background"
        @unknown default: return "unknown"
        }
    }
}
