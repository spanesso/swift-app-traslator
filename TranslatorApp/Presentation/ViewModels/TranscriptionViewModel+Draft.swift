//
//  TranscriptionViewModel+Draft.swift
//  TranslatorApp
//
//  The phrase in progress, kept on disk (2026-09-15).
//
//  A committed phrase is journaled the instant it exists. The words before that — what the
//  speaker is saying right now, the live text on screen — used to live only in memory, for up to
//  three seconds at a time. When the system terminates the app for memory it runs no code at all,
//  so those words were simply gone. They are now journaled as drafts while they change, at most
//  once a second, and immediately when iOS warns about memory or the app leaves the foreground.
//

import Foundation
import OSLog

@MainActor
extension TranscriptionViewModel {

    nonisolated static var draftIntervalMs: Int { 1_000 }

    /// Called on every live-text update. Writes at once if the last draft is old enough,
    /// otherwise schedules one write that picks up the latest text when it fires.
    func persistDraftSoon() {
        guard isRecording, draftTask == nil else { return }
        let sinceLastMs = lastDraftAt.map { MonotonicClock.msSince($0) } ?? Self.draftIntervalMs
        let delayMs = max(0, Self.draftIntervalMs - sinceLastMs)
        draftTask = Task { [weak self] in
            if delayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000) }
            guard let self, !Task.isCancelled else { return }
            self.draftTask = nil
            self.writeDraftNow()
        }
    }

    func writeDraftNow() {
        // A draft scheduled before the meeting ended must not reopen a journal after it.
        guard sessionState != .idle else { return }
        let text = currentBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != lastDraftText else { return }
        // The live text can lag one update behind a commit. A draft that only repeats the phrase
        // just committed would be recovered as a duplicate of it.
        guard !repeatsLastPhrase(text) else { return }
        lastDraftText = text
        lastDraftAt = MonotonicClock.now()
        persist(.draft(text: text, fragmentId: nextFragmentId, sessionId: sessionId, epochMs: Self.nowEpochMs()))
    }

    /// Words still on screen when the pipeline closed without committing them become the last
    /// phrase. They used to disappear with the stop (durability audit 2026-09-15, R9).
    func commitUnconfirmedTail() {
        let text = currentBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
        currentBuffer = ""
        guard !text.isEmpty, !repeatsLastPhrase(text) else { return }
        commitPhrase(SegmentedPhrase(text: text, confidence: 0.5))
    }

    /// Whether `text` is the phrase just committed, seen whole or in part.
    private func repeatsLastPhrase(_ text: String) -> Bool {
        guard let last = fragments.last else { return false }
        let lastKey = Self.dedupKey(last.sourceText)
        let textKey = Self.dedupKey(text)
        return lastKey.hasSuffix(textKey) || textKey.hasSuffix(lastKey)
    }

    func resetDraft() {
        draftTask?.cancel()
        draftTask = nil
        lastDraftText = nil
        lastDraftAt = nil
    }

    /// iOS sometimes warns before terminating for memory — not always, and never with much time.
    /// Whatever is on screen goes to disk now.
    func handleMemoryWarning() {
        telemetry.memoryWarning(sessionId, wasRecording: isRecording)
        logger.warning("[ViewModel] memory warning (recording=\(self.isRecording))")
        guard isRecording else { return }
        writeDraftNow()
    }

    /// Leaving the foreground is when the system is most likely to terminate the app.
    func handleLeavingForeground() {
        guard isRecording else { return }
        writeDraftNow()
    }
}
