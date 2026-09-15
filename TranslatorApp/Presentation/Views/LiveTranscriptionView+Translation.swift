//
//  LiveTranscriptionView+Translation.swift
//  TranslatorApp
//
//  The translation consumption loop (008-fix-audio-pipeline-resilience, US7).
//  Split from LiveTranscriptionView.swift to keep both files under the 250-line convention.
//
//  THE RULE: every request resolves its fragment — translated, empty, too short, or failed.
//  Nothing is dropped. That is what keeps the two exported blocks the same length, and what
//  turns a missing translation into an auditable marker instead of a silent hole.
//

import OSLog
import SwiftUI
import Translation

extension LiveTranscriptionView {

    func runTranslationLoop(session: TranslationSession) async {
        guard let requests = viewModel.translationRequests else {
            viewLogger.warning("⚠️ [UI] .translationTask fired but translationRequests is nil")
            return
        }
        // Only while the pane is empty. `.downloadingModel` replaces the whole Spanish pane with
        // a placeholder, so announcing it on a mid-meeting restart would blank a conversation
        // that is perfectly intact.
        await MainActor.run {
            if viewModel.fragments.isEmpty { viewModel.translatorState = .downloadingModel }
        }
        do {
            try await session.prepareTranslation()
        } catch {
            viewLogger.error("❌ [UI] prepareTranslation failed: \(error.localizedDescription)")
            // 008 (US7): resolve every fragment instead of returning silently. English used
            // to keep accumulating for the whole meeting while the Spanish side stayed
            // empty, and the user only discovered it at export time.
            await MainActor.run {
                viewModel.markSessionTranslationUnavailable()
                viewModel.errorMessage = "The Spanish translation model could not be downloaded. Go to Settings → General → Offline Content → Translation."
                viewModel.hasError = true
            }
            return
        }
        await MainActor.run {
            if viewModel.translatorState == .downloadingModel { viewModel.translatorState = .idle }
        }
        viewLogger.info("🚀 [UI] Translation engine active")

        for await request in requests {
            let sid = viewModel.sessionId
            let trimmed = request.text.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 2 else {
                // Still resolved, not dropped: the fragment keeps its line and carries a
                // marker, so the two exported blocks stay the same length.
                await MainActor.run {
                    viewModel.telemetry.translationSkipped(sid, fragmentId: request.fragmentId,
                                                           chars: trimmed.count, reason: "tooShort")
                    viewModel.markTranslationUnavailable(fragmentId: request.fragmentId,
                                                         reason: .tooShort)
                }
                continue
            }

            let startedAt = MonotonicClock.now()
            await MainActor.run {
                viewModel.telemetry.translationStarted(sid, fragmentId: request.fragmentId,
                                                       queueDepth: viewModel.pendingCount,
                                                       waitedMs: 0)
                // Arms the stall watchdog. This queue is serial on purpose, so one stuck call
                // freezes this pane for the rest of the meeting; the watchdog does not work
                // around that, it makes it visible.
                viewModel.translationDidStart(fragmentId: request.fragmentId)
            }
            do {
                let response = try await session.translate(request.text)
                let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsedMs = MonotonicClock.msSince(startedAt)
                await MainActor.run {
                    viewModel.translationDidFinish(fragmentId: request.fragmentId)
                    viewModel.telemetry.translationDone(sid, fragmentId: request.fragmentId,
                                                        translateMs: elapsedMs,
                                                        endToEndMs: elapsedMs,
                                                        queueDepth: viewModel.pendingCount)
                    // A service handed a fragment it cannot work with may echo the input back.
                    // Stored as a translation, that is English sitting in the Spanish pane
                    // looking exactly like a real result.
                    viewModel.resolveTranslation(
                        fragmentId: request.fragmentId,
                        outcome: .forResult(translated, source: request.text))
                }
            } catch {
                let description = error.localizedDescription
                viewLogger.error("❌ [UI] Translation error: \(description)")
                await MainActor.run {
                    viewModel.translationDidFinish(fragmentId: request.fragmentId)
                    viewModel.telemetry.translationFailed(sid, fragmentId: request.fragmentId,
                                                          error: description,
                                                          sourceChars: trimmed.count)
                    viewModel.markTranslationUnavailable(fragmentId: request.fragmentId,
                                                         reason: .failed)
                    let lowercased = description.lowercased()
                    if lowercased.contains("model") || lowercased.contains("download") {
                        viewModel.translatorState = .modelUnavailable
                        viewModel.errorMessage = "The Spanish translation model is no longer available. Go to Settings → General → Offline Content → Translation."
                        viewModel.hasError = true
                    }
                }
            }
        }
        viewLogger.info("🏁 [UI] Translation stream closed")
    }
}
