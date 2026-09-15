//
//  LiveTranscriptionView+SessionActions.swift
//  TranslatorApp
//
//  Save, export and discard for a finished meeting (2026-09-15).
//  Split from LiveTranscriptionView.swift to keep both under the 250-line convention.
//
//  The user decides what happens to a meeting. Exporting is always available — saved or not —
//  and is the only way any of it leaves the app, always by the user's hand.
//

import SwiftUI

extension LiveTranscriptionView {

    @ViewBuilder
    var sessionActionsView: some View {
        if viewModel.canSave {
            Button {
                Task { await viewModel.saveConversation() }
            } label: {
                Label(viewModel.isArchived ? "Saved" : "Save",
                      systemImage: viewModel.isArchived ? "lock.fill" : "lock.doc")
                    .font(.system(size: 11, weight: .medium))
            }
            .disabled(viewModel.isSaving || viewModel.isArchived)
            .buttonStyle(.borderedProminent)
            .tint(viewModel.isArchived ? .green : .blue)
            .help("Save encrypted on this device. Only you can open it.")

            ShareLink(item: viewModel.exportDocument,
                      preview: SharePreview(viewModel.exportDocument.filename)) {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.bordered)

            if viewModel.hasUnsavedMeeting {
                Button(role: .destructive) {
                    viewModel.requestDiscard()
                } label: {
                    Label("Discard", systemImage: "trash")
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(.bordered)
            }
        }
    }

    /// Says plainly that the meeting is not saved yet — and that it is safe until the user decides.
    var unsavedMeetingBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.lock.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("This meeting is not saved yet")
                    .font(.system(size: 12, weight: .semibold))
                Text("Save it encrypted, export it, or discard it. Until you decide, it stays on this device.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.top, 8)
        .padding(.horizontal, 60)
        .frame(maxWidth: .infinity, alignment: .top)
    }
}
