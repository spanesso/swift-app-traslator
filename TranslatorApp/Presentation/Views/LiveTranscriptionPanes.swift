//
//  LiveTranscriptionPanes.swift
//  TranslatorApp
//
//  Extracted subviews to keep LiveTranscriptionView.swift under 250 lines.
//

import SwiftUI

extension LiveTranscriptionView {

    func headerView(title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.system(size: 10, weight: .bold))
        }
        .padding([.horizontal, .top])
        .foregroundStyle(.secondary)
    }

    // MARK: - English pane

    func englishPane() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.emittedPhrases.isEmpty && viewModel.currentBuffer.isEmpty {
                        Text("Waiting for audio...")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        ForEach(Array(viewModel.emittedPhrases.enumerated()), id: \.offset) { _, phrase in
                            Text(phrase)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        // Live buffer: opacity tracks latest segment confidence
                        let bufferOpacity = Double(max(0.55, viewModel.latestSegmentConfidence))
                        Text(viewModel.currentBuffer)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green.opacity(bufferOpacity))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }

                    Color.clear.frame(height: 1).id("raw_end")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.currentBuffer) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("raw_end", anchor: .bottom) }
            }
            .onChange(of: viewModel.emittedPhrases.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("raw_end", anchor: .bottom) }
            }
        }
    }

    // MARK: - Spanish pane

    func spanishPane() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.translatorState == .downloadingModel {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.2)
                            Text("Downloading translation model…\nThis only happens once.")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 40)
                        .padding(.horizontal)
                    } else if viewModel.translatorState == .modelUnavailable {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Translation model unavailable", systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(.orange)
                            Text("To fix this, go to:\nSettings → General → Offline Content → Translation\nand download the Spanish language pack.")
                                .font(.system(size: 13, weight: .regular))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal)
                    } else if viewModel.translatedSentences.isEmpty {
                        Text("Waiting for translation...")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        let entries = viewModel.translatedSentences
                        let lastIndex = entries.count - 1
                        ForEach(Array(entries.enumerated()), id: \.offset) { index, entry in
                            let isLast = index == lastIndex
                            // Tonal opacity: dim low-confidence translations, full-bright for recent
                            let confidence = Double(entry.minSourceConfidence)
                            let opacity = isLast
                                ? max(0.65, confidence)
                                : max(0.35, confidence * 0.75)
                            Text(entry.text)
                                .font(.system(size: isLast ? 20 : 18,
                                              weight: isLast ? .semibold : .medium))
                                .foregroundStyle(
                                    (isLast ? Color.white : Color.cyan).opacity(opacity)
                                )
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .id(isLast ? "tr_end" : "tr_\(index)")
                        }
                    }

                    Color.clear.frame(height: 1).id("tr_bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.translatedSentences.count) { _, _ in
                Task { @MainActor in
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo("tr_bottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}
