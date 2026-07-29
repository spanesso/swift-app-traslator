//
//  LiveTranscriptionView+Alerts.swift
//  TranslatorApp
//
//  Alerts and confirmations for the recording session.
//  Split from LiveTranscriptionView.swift to keep both under the 250-line convention.
//
//  Two of these exist because a user lost a real meeting: the recovery prompt for a session the
//  app never got to finish, and the confirmation before a new recording clears the screen
//  (010-transcript-durability, US2 and US4).
//

import SwiftUI

private struct SessionAlertsModifier: ViewModifier {
    @Bindable var viewModel: TranscriptionViewModel

    private static let recoveryDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    func body(content: Content) -> some View {
        content
            .alert(alertTitle, isPresented: $viewModel.hasError) {
                Button("OK", role: .cancel) { viewModel.translatorState = .idle }
            } message: {
                if let error = viewModel.errorMessage { Text(error) }
            }
            // A meeting the app never got to finish. Recovering is the default; discarding is
            // destructive and is marked as such (FR-012).
            .alert("Unfinished meeting found",
                   isPresented: .constant(viewModel.recoverableSession != nil)) {
                Button("Recover") { viewModel.recoverPendingSession() }
                Button("Discard", role: .destructive) { viewModel.discardPendingSession() }
            } message: {
                if let recovered = viewModel.recoverableSession {
                    Text(recoveryMessage(for: recovered))
                }
            }
            // Starting a new meeting clears the screen. It used to do that silently, on one tap,
            // with no way back (FR-019).
            .confirmationDialog("Start a new recording?",
                                isPresented: $viewModel.pendingNewSessionConfirmation,
                                titleVisibility: .visible) {
                Button("Start new recording", role: .destructive) {
                    viewModel.confirmStartNewSession()
                }
                Button("Cancel", role: .cancel) { viewModel.cancelStartNewSession() }
            } message: {
                Text(viewModel.newSessionConfirmationMessage)
            }
            .task {
                await viewModel.checkForRecoverableSession()
            }
    }

    private func recoveryMessage(for recovered: RecoveredSession) -> String {
        let count = recovered.fragments.count
        let when = Self.recoveryDateFormatter.string(from: recovered.startedAt)
        let phrases = count == 1 ? "1 phrase was" : "\(count) phrases were"
        return "The app closed during a meeting on \(when). \(phrases) saved and can be restored."
    }

    private var alertTitle: String {
        switch viewModel.translatorState {
        case .permissionDenied:             return "Permission Required"
        case .modelUnavailable:             return "Translation Model Unavailable"
        case .downloadingModel:             return "Downloading Model"
        case .downloadingASRModel:          return "Downloading ASR Model"
        case .suspendedByAudioInterruption: return "Recording Paused"
        default:                            return "Error"
        }
    }
}

extension View {
    func sessionAlerts(viewModel: TranscriptionViewModel) -> some View {
        modifier(SessionAlertsModifier(viewModel: viewModel))
    }
}
