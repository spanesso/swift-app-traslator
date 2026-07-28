//
//  LiveTranscriptionPanes.swift
//  TranslatorApp
//
//  Extracted subviews to keep LiveTranscriptionView.swift under 250 lines.
//
//  008 (US7): both panes now render from the SAME ordered array of fragments. They used to walk
//  two independent arrays by offset, so any filter that shrank one side shifted every later row
//  against its counterpart — visibly, and then permanently in the export.
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
                // LazyVStack: history is unbounded and append-only, so only render what is visible.
                LazyVStack(alignment: .leading, spacing: 8) {
                    if viewModel.fragments.isEmpty && viewModel.currentBuffer.isEmpty {
                        Text("Waiting for audio...")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        ForEach(viewModel.fragments) { fragment in
                            Text(fragment.sourceText)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        // Live tail: opacity tracks the latest segment's confidence.
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
            .onChange(of: viewModel.fragments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("raw_end", anchor: .bottom) }
            }
        }
    }

    // MARK: - Spanish pane

    func spanishPane() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    switch viewModel.translatorState {
                    case .downloadingModel:
                        downloadingPlaceholder
                    case .modelUnavailable:
                        modelUnavailablePlaceholder
                    default:
                        if viewModel.fragments.isEmpty {
                            Text("Waiting for translation...")
                                .font(.system(size: 14, weight: .regular))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        } else {
                            translatedRows
                        }
                    }
                    Color.clear.frame(height: 1).id("tr_bottom")
                }
                .padding(.vertical, 8)
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: viewModel.fragments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("tr_bottom", anchor: .bottom) }
            }
        }
    }

    /// One row per fragment, always. A fragment whose translation is missing shows the marker
    /// rather than disappearing — a visible gap is auditable, an invisible one is not.
    @ViewBuilder
    private var translatedRows: some View {
        let lastId = viewModel.fragments.last?.id
        ForEach(viewModel.fragments) { fragment in
            let isLast = fragment.id == lastId
            switch fragment.translation {
            case .pending:
                Text(fragment.sourceText)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.white.opacity(0.25))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            case .translated(let text):
                let confidence = Double(fragment.sourceConfidence)
                let opacity = isLast ? max(0.65, confidence) : max(0.35, confidence * 0.75)
                Text(text)
                    .font(.system(size: isLast ? 20 : 18, weight: isLast ? .semibold : .medium))
                    .foregroundStyle((isLast ? Color.white : Color.cyan).opacity(opacity))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            case .unavailable(let reason):
                Label(reason.shortDescription, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(.orange.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
        }
    }

    private var downloadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().scaleEffect(1.2)
            Text("Downloading translation model…\nThis only happens once.")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.horizontal)
    }

    private var modelUnavailablePlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Translation model unavailable", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.orange)
            Text("To fix this, go to:\nSettings → General → Offline Content → Translation\nand download the Spanish language pack.")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }
}
