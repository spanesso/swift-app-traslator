//
//  LiveTranscriptionView.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
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

            VStack(spacing: 10) {
                Button { showHistory = true } label: {
                    Image(systemName: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .help("Conversation History")

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
        .translationTask(translationConfig) { session in
            guard let requests = viewModel.translationRequests else {
                viewLogger.warning("⚠️ [UI] .translationTask fired but translationRequests is nil — skipping")
                return
            }
            viewLogger.info("🚀 [UI] Translation engine active")
            var seq = 0
            for await sentence in requests {
                guard sentence.trimmingCharacters(in: .whitespaces).count > 2 else { continue }
                let id = seq; seq += 1
                let t0 = Date()
                viewLogger.info("[TRANSLATE-START id=\(id)] '\(sentence)'")
                do {
                    let response = try await session.translate(sentence)
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    viewLogger.info("[TRANSLATE-DONE id=\(id) ms=\(ms)] '\(translated)'")
                    await MainActor.run { viewModel.appendTranslation(translated) }
                } catch {
                    viewLogger.error("❌ [UI] Translation error: \(error.localizedDescription)")
                    if error.localizedDescription.lowercased().contains("model") ||
                       error.localizedDescription.lowercased().contains("download") {
                        await MainActor.run {
                            viewModel.translatorState = .modelUnavailable
                            viewModel.errorMessage = "The Spanish translation model is not available. Open System Settings to download the Spanish language pack."
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
        .sheet(isPresented: $showHistory) {
            NavigationStack {
                ConversationHistoryView(viewModel: historyViewModel)
            }
            .frame(minWidth: 700, idealWidth: 900, minHeight: 500, idealHeight: 650)
            .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
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
        default: return "Error"
        }
    }
}
