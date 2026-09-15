//
//  ConversationHistoryView.swift
//  TranslatorApp
//
//  Saved conversations are private (2026-09-15): the list shows when each one was saved and
//  nothing of what was said. Opening one asks the user to confirm it is them.
//

import SwiftUI

struct ConversationHistoryView: View {
    var viewModel: ConversationHistoryViewModel

    var body: some View {
        ZStack {
            Color(white: 0.07).ignoresSafeArea()
            if viewModel.isLoading {
                ProgressView("Loading…").tint(.white)
            } else if viewModel.conversations.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(viewModel.conversations) { summary in
                            Button {
                                Task { await viewModel.open(summary) }
                            } label: {
                                ConversationCard(summary: summary,
                                                 isOpening: viewModel.openingId == summary.id)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.openingId != nil)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Conversations")
        .navigationDestination(isPresented: Binding(
            get: { viewModel.openedConversation != nil },
            set: { if !$0 { viewModel.closeConversation() } }
        )) {
            if let conversation = viewModel.openedConversation {
                ConversationDetailView(conversation: conversation)
            }
        }
        .preferredColorScheme(.dark)
        .task { await viewModel.loadConversations() }
        .alert("Error", isPresented: .constant(viewModel.errorMessage != nil)) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.doc.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Conversations Yet")
                .font(.title2.weight(.semibold))
            Text("Conversations you save are encrypted on this device.\nOnly you can open them.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

private struct ConversationCard: View {
    let summary: ConversationSummary
    let isOpening: Bool

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill")
                .font(.system(size: 14))
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: summary.savedAt))
                    .font(.system(size: 13, weight: .semibold))
                Text("Encrypted · only you can open it")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isOpening {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.blue.opacity(0.8))
            }
        }
        .padding(14)
        .background(Color(white: 0.14))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.white.opacity(0.07), lineWidth: 1)
        )
    }
}
