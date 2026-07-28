//
//  EnginePreferenceView.swift
//  TranslatorApp
//
//  Engine selection UI. Presented as a sheet from LiveTranscriptionView.
//
//  008 (US4): the on-device WhisperKit engine is withdrawn in this build. It is shown as
//  unavailable, with the reason, rather than offered as a choice that silently fails — which is
//  what it was: it re-processed the whole accumulated session every two seconds and marked
//  every result as a hypothesis, so nothing ever reached the translation layer.
//

import SwiftUI

struct EnginePreferenceView: View {
    var viewModel: TranscriptionViewModel

    private var availablePreferences: [EnginePreference] {
        EnginePreference.allCases.filter(\.isAvailable)
    }

    private var withdrawnPreferences: [EnginePreference] {
        EnginePreference.allCases.filter { !$0.isAvailable }
    }

    /// A stored preference pointing at a withdrawn engine still resolves to the Apple route.
    private var effectivePreference: EnginePreference {
        viewModel.enginePreference.isAvailable ? viewModel.enginePreference : .auto
    }

    var body: some View {
        Form {
            Section {
                Picker("Engine", selection: Binding(
                    get: { effectivePreference },
                    set: { viewModel.saveEnginePreference($0) }
                )) {
                    ForEach(availablePreferences, id: \.self) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Speech Recognition Engine")
            } footer: {
                Text(footerText).font(.caption)
            }

            if !withdrawnPreferences.isEmpty {
                Section("Unavailable in this build") {
                    ForEach(withdrawnPreferences, id: \.self) { pref in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(pref.displayName)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Image(systemName: "slash.circle").foregroundStyle(.secondary)
                            }
                            if let reason = pref.unavailableReason {
                                Text(reason)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }

            Section("Device") {
                deviceCapabilityRow
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
                Text("A17 Pro Neural Engine").font(.subheadline)
                Text(hasA17
                     ? "On-device transcript correction available"
                     : "On-device transcript correction unavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footerText: String {
        switch effectivePreference {
        case .auto, .whisperPreferred:
            return "Uses Apple on-device speech recognition. Recognition runs entirely on this device; no audio leaves it."
        case .appleOnly:
            return "Always uses Apple speech recognition. Lower battery use."
        }
    }
}
