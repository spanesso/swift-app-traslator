//
//  LiveTranscriptionView.swift
//  TranslatorApp
//

import SwiftUI
import Translation
import OSLog

struct LiveTranscriptionView: View {
    var viewModel: TranscriptionViewModel
    var historyViewModel: ConversationHistoryViewModel

    @State private var translationConfig: TranslationSession.Configuration?
    @State private var taskID = UUID()
    @State private var showHistory: Bool = false
    @State private var showEngineSettings: Bool = false

    let viewLogger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UI")

    init(viewModel: TranscriptionViewModel, historyViewModel: ConversationHistoryViewModel) {
        self.viewModel = viewModel
        self.historyViewModel = historyViewModel
    }

    var body: some View {
        @Bindable var bindable = viewModel

        ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        headerView(title: "ORIGINAL (EN)", icon: "microphone.fill", color: .yellow)
                        englishPane()
                    }
                    .frame(width: totalWidth * 0.35)
                    .padding(.top)
                    .background(Color(white: 0.12))

                    Divider().background(Color.gray.opacity(0.3))

                    VStack(alignment: .leading, spacing: 8) {
                        headerView(title: "OFFLINE TRANSLATION (ES)", icon: "character.bubble.fill", color: .blue)
                        spanishPane()
                    }
                    .frame(width: totalWidth * 0.60)
                    .padding(.top)
                    .background(Color(white: 0.08))

                    VStack {}
                        .frame(width: totalWidth * 0.05)
                        .background(Color(white: 0.08))
                }
            }
            .ignoresSafeArea(edges: .bottom)

            // Suspension banner (008 US5): a recoverable pause, stated honestly. This is what
            // replaces the "Permission Required" alert every interruption used to raise.
            if let reason = viewModel.suspensionReason {
                suspensionBanner(reason: reason)
            }

            // Sidebar buttons
            VStack(spacing: 10) {
                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .help("Conversation History")

                Button { showEngineSettings = true } label: {
                    Image(systemName: "waveform.badge.mic")
                }
                .buttonStyle(.bordered)
                .help("Engine Settings")

                engineModeChip

                RecordButton(isRecording: viewModel.isRecording) {
                    viewModel.toggleRecording()
                }

                if viewModel.isRecording {
                    Button { viewModel.restartListening() } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .help("Restart Listening")
                }

                sessionActionsView
            }
            .padding(.top, 15)
            .padding(.trailing, 5)
        }
        .alert(alertTitle, isPresented: $bindable.hasError) {
            Button("OK", role: .cancel) { viewModel.translatorState = .idle }
        } message: {
            if let error = viewModel.errorMessage { Text(error) }
        }
        .sheet(isPresented: $showEngineSettings) {
            NavigationStack { EnginePreferenceView(viewModel: viewModel) }
                .frame(minWidth: 360, idealWidth: 420, minHeight: 280, idealHeight: 340)
                .preferredColorScheme(.dark)
        }
        .translationTask(translationConfig) { session in
            await runTranslationLoop(session: session)
        }
        .id(taskID)
        .onChange(of: viewModel.isRecording) { _, isRecording in
            if isRecording {
                taskID = UUID()
                translationConfig = .init(
                    source: .init(identifier: "en-US"),
                    target: .init(identifier: "es-ES")
                )
            } else {
                translationConfig = nil
            }
        }
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                ConversationHistoryView(viewModel: historyViewModel)
            }
            .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 650)
            .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Suspension banner

    /// Shown while capture is paused by a system sound, a call, or a device change. It says the
    /// session will resume by itself, because it will — including when the user never touches
    /// the alarm or the incoming call.
    @ViewBuilder
    private func suspensionBanner(reason: AudioInterruptionReason) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "pause.circle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Recording paused")
                    .font(.system(size: 12, weight: .semibold))
                Text(reason.userFacingMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ProgressView().controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: - Engine mode chip

    private var engineModeLabel: String {
        switch viewModel.enginePreference {
        case .auto:             return "AUTO"
        case .appleOnly:        return "APPLE"
        case .whisperPreferred: return "WHISPER"
        }
    }

    private var engineModeChip: some View {
        Text(engineModeLabel)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.25))
            .clipShape(Capsule())
            .foregroundStyle(.blue)
    }

    // MARK: - Session actions

    @ViewBuilder
    private var sessionActionsView: some View {
        if viewModel.canSave {
            Button {
                Task { await viewModel.saveConversation() }
            } label: {
                Label(
                    viewModel.savedSuccessfully ? "Saved!" : "Save",
                    systemImage: viewModel.savedSuccessfully ? "checkmark.circle.fill" : "square.and.arrow.down"
                )
                .font(.system(size: 11, weight: .medium))
            }
            .disabled(viewModel.isSaving)
            .buttonStyle(.borderedProminent)
            .tint(viewModel.savedSuccessfully ? .green : .blue)

            ShareLink(item: viewModel.exportDocument,
                      preview: SharePreview(viewModel.exportDocument.filename)) {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Alert

    private var alertTitle: String {
        switch viewModel.translatorState {
        case .permissionDenied: return "Permission Required"
        case .modelUnavailable: return "Translation Model Unavailable"
        case .downloadingModel: return "Downloading Model"
        case .downloadingASRModel: return "Downloading ASR Model"
        // Never surfaces as an alert — the banner handles it — but the case must be honest if
        // it ever reaches here. This is exactly what used to be titled "Permission Required".
        case .suspendedByAudioInterruption: return "Recording Paused"
        default: return "Error"
        }
    }
}
