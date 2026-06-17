//
//  EnginePreferenceView.swift
//  TranslatorApp
//
//  Engine selection UI: Auto / Apple SpeechAnalyzer / WhisperKit.
//  Presented as a sheet from LiveTranscriptionView.
//

import SwiftUI

struct EnginePreferenceView: View {
    var viewModel: TranscriptionViewModel

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: Binding(
                    get: { viewModel.enginePreference },
                    set: { viewModel.saveEnginePreference($0) }
                )) {
                    ForEach(EnginePreference.allCases, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Speech Recognition Engine")
            } footer: {
                Text(footerText)
                    .font(.caption)
            }

            Section("Device") {
                deviceCapabilityRow
            }

            if case .awaitingConsent = viewModel.modelInstallState {
                Section("WhisperKit Model") {
                    HStack {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Ready to download").font(.subheadline)
                            Text("~600 MB, Wi-Fi required").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Download") { viewModel.acceptModelDownload() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            } else if case .downloading(let progress) = viewModel.modelInstallState {
                Section("WhisperKit Model") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text("Downloading…")
                            Spacer()
                            Text("\(Int(progress * 100))%").foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress).tint(.blue)
                    }
                }
            } else if case .installed(let version, _) = viewModel.modelInstallState {
                Section("WhisperKit Model") {
                    Label("Installed (\(version))", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            } else if case .failed(let reason) = viewModel.modelInstallState {
                Section("WhisperKit Model") {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(reason.userFacingMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("Retry") { viewModel.acceptModelDownload() }
                    }
                }
            } else if case .declined = viewModel.modelInstallState {
                Section("WhisperKit Model") {
                    HStack {
                        Text("Download declined")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Download Now") { viewModel.acceptModelDownload() }
                    }
                }
            }
        }
        .navigationTitle("Engine Settings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Helpers

    @ViewBuilder
    private var deviceCapabilityRow: some View {
        let hasA17 = DeviceCapabilities.supportsA17Pro
        HStack {
            Image(systemName: hasA17 ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(hasA17 ? .green : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("A17 Pro Neural Engine")
                    .font(.subheadline)
                Text(hasA17
                     ? "WhisperKit and Foundation Models available"
                     : "Apple SpeechAnalyzer only (no WhisperKit)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerText: String {
        switch viewModel.enginePreference {
        case .auto:
            return "Automatically selects WhisperKit on A17 Pro+ when installed, otherwise uses Apple SpeechAnalyzer."
        case .appleOnly:
            return "Always uses Apple SpeechAnalyzer. Lower battery use; reduced accent robustness."
        case .whisperPreferred:
            return "Requires A17 Pro+ and WhisperKit model (~600 MB). Best accuracy for non-native English speakers."
        }
    }
}
