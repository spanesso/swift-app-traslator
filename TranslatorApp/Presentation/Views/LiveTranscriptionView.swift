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
    @State private var showWhisperConsent: Bool = false
    @State private var showEngineSettings: Bool = false

    private let viewLogger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UI")

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

            // Download progress overlay
            if case .downloading(let progress) = viewModel.modelInstallState {
                asmrDownloadBanner(progress: progress)
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
        .confirmationDialog("Upgrade ASR Engine?", isPresented: $showWhisperConsent, titleVisibility: .visible) {
            Button("Download (~600 MB via Wi-Fi)") { viewModel.acceptModelDownload() }
            Button("Not Now", role: .cancel) { viewModel.declineModelDownload() }
        } message: {
            Text("WhisperKit improves accuracy for non-native English speakers (Italian, Indian, Latino accents). Requires Wi-Fi. Download happens once in the background.")
        }
        .sheet(isPresented: $showEngineSettings) {
            NavigationStack { EnginePreferenceView(viewModel: viewModel) }
                .frame(minWidth: 360, idealWidth: 420, minHeight: 280, idealHeight: 340)
                .preferredColorScheme(.dark)
        }
        .translationTask(translationConfig) { session in
            guard let requests = viewModel.translationRequests else {
                viewLogger.warning("⚠️ [UI] .translationTask fired but translationRequests is nil")
                return
            }
            await MainActor.run { viewModel.translatorState = .downloadingModel }
            do {
                try await session.prepareTranslation()
            } catch {
                viewLogger.error("❌ [UI] prepareTranslation failed: \(error.localizedDescription)")
                await MainActor.run {
                    viewModel.translatorState = .modelUnavailable
                    viewModel.errorMessage = "The Spanish translation model could not be downloaded. Go to Settings → General → Offline Content → Translation."
                    viewModel.hasError = true
                }
                return
            }
            await MainActor.run {
                if viewModel.translatorState == .downloadingModel { viewModel.translatorState = .idle }
            }
            viewLogger.info("🚀 [UI] Translation engine active")
            var seq = 0
            for await request in requests {
                guard request.text.trimmingCharacters(in: .whitespaces).count > 2 else { continue }
                let id = seq; seq += 1
                let t0 = Date()
                viewLogger.info("[TRANSLATE-START id=\(id)] '\(request.text)'")
                do {
                    let response = try await session.translate(request.text)
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewLogger.info("[TRANSLATE-DONE id=\(id) ms=\(ms)] '\(translated)'")
                    await MainActor.run {
                        viewModel.appendTranslation(translated, sourceConfidence: request.sourceConfidence)
                    }
                } catch {
                    viewLogger.error("❌ [UI] Translation error: \(error.localizedDescription)")
                    if error.localizedDescription.lowercased().contains("model") ||
                       error.localizedDescription.lowercased().contains("download") {
                        await MainActor.run {
                            viewModel.translatorState = .modelUnavailable
                            viewModel.errorMessage = "The Spanish translation model is no longer available. Go to Settings → General → Offline Content → Translation."
                            viewModel.hasError = true
                        }
                    } else if error.localizedDescription.contains("interrupted") {
                        await MainActor.run { viewModel.stopRecording() }
                    }
                }
            }
            viewLogger.info("🏁 [UI] Translation stream closed")
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
        .onChange(of: viewModel.modelInstallState) { _, state in
            if case .awaitingConsent = state { showWhisperConsent = true }
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

    // MARK: - Download progress banner

    @ViewBuilder
    private func asmrDownloadBanner(progress: Double) -> some View {
        VStack(spacing: 4) {
            HStack {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                Text("Downloading WhisperKit model…")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress)
                .tint(.blue)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
        .padding(.horizontal, 80)
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
        default: return "Error"
        }
    }
}
