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
        ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width

                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        headerView(title: "ORIGINAL (EN)", icon: "microphone.fill", color: .yellow)
                        inputLevelMeter()
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
            } else if viewModel.hasUnsavedMeeting {
                unsavedMeetingBanner
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
                // Until the last meeting has delivered its last phrase.
                .disabled(viewModel.sessionState == .stopping)

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

            translationTaskHost
        }
        .sessionAlerts(viewModel: viewModel)
        .sheet(isPresented: $showEngineSettings) {
            NavigationStack { EnginePreferenceView(viewModel: viewModel) }
                .frame(minWidth: 360, idealWidth: 420, minHeight: 280, idealHeight: 340)
                .preferredColorScheme(.dark)
        }
        // Follows the STREAM, not the record button. Keyed on `isRecording`, a manual restart —
        // which swaps the stream without ever leaving the recording state — left the new stream
        // with no consumer, and every phrase from that tap onwards sat on "Translating…" for the
        // rest of the meeting with nothing reported anywhere.
        .onChange(of: viewModel.translationStreamId) { _, streamId in
            guard streamId != nil else {
                translationConfig = nil
                return
            }
            // ORDER IS LOAD-BEARING: the id rotates FIRST so SwiftUI destroys the previous
            // `.translationTask` subtree before the new configuration starts a task.
            taskID = UUID()
            translationConfig = .init(
                source: .init(identifier: "en-US"),
                target: .init(identifier: "es-ES")
            )
        }
        // The decrypted conversation goes as soon as the history is dismissed.
        .sheet(isPresented: $showHistory, onDismiss: { historyViewModel.closeConversation() }) {
            NavigationStack {
                ConversationHistoryView(viewModel: historyViewModel)
            }
            .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 650)
            .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Translation task host

    /// Invisible node that owns the translation consumer.
    ///
    /// The rotating `.id` used to sit on the whole screen, so every restart of the consumer also
    /// rebuilt both panes, reset their scroll position and re-ran the recovery check. Nothing
    /// about that was needed: only the `.translationTask` subtree has to be destroyed.
    private var translationTaskHost: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .translationTask(translationConfig) { session in
                await runTranslationLoop(session: session)
            }
            .id(taskID)
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
}
