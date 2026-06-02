//
//  ConversationDetailView.swift
//  TranslatorApp
//

import SwiftUI

struct ConversationDetailView: View {
    let conversation: ConversationEntity

    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let exportDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm"
        return f
    }()

    private var exportDocument: ConversationExport {
        let en = conversation.englishText.isEmpty ? "(no transcript)" : conversation.englishText
        let es = conversation.spanishText.isEmpty ? "(no translation)" : conversation.spanishText
        let content = "=== ENGLISH TRANSCRIPT ===\n\n\(en)\n\n=== SPANISH TRANSLATION ===\n\n\(es)"
        let dateStr = Self.exportDateFormatter.string(from: conversation.savedAt)
        return ConversationExport(content: content, filename: "Conversation \(dateStr).txt")
    }

    var body: some View {
        VStack(spacing: 0) {
            exportBanner
            GeometryReader { geo in
                HStack(spacing: 0) {
                    englishPanel(width: geo.size.width * 0.5)
                    Divider().background(Color.white.opacity(0.1))
                    spanishPanel(width: geo.size.width * 0.5)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .navigationTitle(Self.titleFormatter.string(from: conversation.savedAt))
        .preferredColorScheme(.dark)
    }

    // MARK: - Export Banner

    private var exportBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "doc.text.fill")
                .foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 1) {
                Text("Conversation")
                    .font(.system(size: 13, weight: .semibold))
                Text(Self.titleFormatter.string(from: conversation.savedAt))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            ShareLink(item: exportDocument, preview: SharePreview(exportDocument.filename)) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.up")
                    Text("Export / AirDrop")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Color.blue)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(white: 0.11))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.08)), alignment: .bottom)
    }

    // MARK: - Panels

    private func englishPanel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(label: "ENGLISH TRANSCRIPT", icon: "text.bubble.fill", color: .yellow)
            ScrollView {
                let text = conversation.englishText
                Text(text.isEmpty ? "No transcript available." : text)
                    .font(.system(size: 13, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(text.isEmpty ? 0.35 : 0.9))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .frame(width: width)
        .background(Color(white: 0.11))
    }

    private func spanishPanel(width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            panelHeader(label: "TRADUCCIÓN (ES)", icon: "character.bubble.fill", color: .blue)
            ScrollView {
                let text = conversation.spanishText
                Text(text.isEmpty ? "No translation available." : text)
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(Color.white.opacity(text.isEmpty ? 0.35 : 1.0))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
            }
        }
        .frame(width: width)
        .background(Color(white: 0.07))
    }

    private func panelHeader(label: String, icon: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(color).font(.system(size: 11))
            Text(label).font(.system(size: 10, weight: .bold)).foregroundStyle(color)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(white: 0.08))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(Color.white.opacity(0.07)), alignment: .bottom)
    }
}
