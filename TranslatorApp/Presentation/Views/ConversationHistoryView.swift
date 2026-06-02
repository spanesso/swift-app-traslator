//
//  ConversationHistoryView.swift
//  TranslatorApp
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
                        ForEach(viewModel.conversations, id: \.id) { conv in
                            NavigationLink(destination: ConversationDetailView(conversation: conv)) {
                                ConversationCard(conversation: conv)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
            }
        }
        .navigationTitle("Conversations")
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
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("No Conversations Yet")
                .font(.title2.weight(.semibold))
            Text("Conversations you save during a live session\nwill appear here.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

private struct ConversationCard: View {
    let conversation: ConversationEntity

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private var wordCount: Int {
        conversation.englishText.split(whereSeparator: \.isWhitespace).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.and.mic")
                        .font(.system(size: 12))
                        .foregroundStyle(.yellow)
                    Text(Self.dateFormatter.string(from: conversation.savedAt))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(wordCount) words")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Color.blue.opacity(0.15))
                    .clipShape(Capsule())
            }

            Text(conversation.preview)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.65))
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: "arrow.right.circle")
                    .font(.system(size: 10))
                Text("View full conversation")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.blue.opacity(0.8))
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
