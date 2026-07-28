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
        await MainActor.run { viewModel.translatorState = .downloadingModel }
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
            }
            do {
                let response = try await session.translate(request.text)
                let translated = response.targetText.trimmingCharacters(in: .whitespacesAndNewlines)
                let elapsedMs = MonotonicClock.msSince(startedAt)
                await MainActor.run {
                    viewModel.telemetry.translationDone(sid, fragmentId: request.fragmentId,
                                                        translateMs: elapsedMs,
                                                        endToEndMs: elapsedMs,
                                                        queueDepth: viewModel.pendingCount)
                    viewModel.resolveTranslation(
                        fragmentId: request.fragmentId,
                        outcome: translated.isEmpty ? .unavailable(.emptyResult)
                                                    : .translated(translated))
                }
            } catch {
                let description = error.localizedDescription
                viewLogger.error("❌ [UI] Translation error: \(description)")
                await MainActor.run {
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
