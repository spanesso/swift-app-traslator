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

                        Text(viewModel.currentBuffer)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)
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

    func spanishPane() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.translatorState == .modelUnavailable {
                        Text("Translation model not available.\nPlease download the Spanish language pack in System Settings.")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.orange)
                            .padding(.horizontal)
                    } else if viewModel.translatedSentences.isEmpty {
                        Text("Waiting for translation...")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        let sentences = viewModel.translatedSentences
                        let lastIndex = sentences.count - 1
                        ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                            let isLast = index == lastIndex
                            Text(sentence)
                                .font(.system(size: isLast ? 20 : 18,
                                              weight: isLast ? .semibold : .medium))
                                .foregroundStyle(isLast ? Color.white : Color.cyan)
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
        .overlay {
            if case .modelDownloading(let progress) = viewModel.translatorState {
                downloadProgressOverlay(progress: progress)
            }
        }
    }

    @ViewBuilder
    private func downloadProgressOverlay(progress: Double) -> some View {
        ZStack {
            Color.black.opacity(0.80)
            VStack(spacing: 16) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 36))
                    .foregroundStyle(.blue)
                Text("Downloading recognition model…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white)
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .frame(maxWidth: 260)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.8))
                Text("This one-time download (~632 MB) enables\naccurate recognition of any English accent.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
            .padding(32)
        }
        .ignoresSafeArea()
    }
}
