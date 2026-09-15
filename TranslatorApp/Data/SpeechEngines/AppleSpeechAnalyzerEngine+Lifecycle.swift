//
//  AppleSpeechAnalyzerEngine+Lifecycle.swift
//  TranslatorApp
//
//  Stopping, and reacting to the audio system (SpeechAnalyzer migration, 2026-09-15).
//  Split from AppleSpeechAnalyzerEngine.swift to keep both under the 250-line convention.
//
//  Same rules as the classic engine: an interruption SUSPENDS (the analyser simply receives no
//  audio for a while), a stop waits a bounded moment for what was already heard to be finalised,
//  and a stop that lands during start wins.
//

import AVFoundation
import OSLog
import Speech

extension AppleSpeechAnalyzerEngine {

    nonisolated static var finalizeBudgetMs: Int { 2_000 }
    nonisolated static var resultsDrainBudgetMs: Int { 1_000 }

    func stop() async {
        lifecycleEpoch += 1
        guard !isStopping else { return }
        isStopping = true
        logger.info("[SpeechAnalyzer] stop")
        telemetry.sessionEnd(sessionId, reason: .userStop, errorDomain: nil, errorCode: nil,
                             durationMs: MonotonicClock.msSince(sessionStartedAt), restartIndex: 0)
        resilienceTask?.cancel(); resilienceTask = nil
        pacerTask?.cancel(); pacerTask = nil

        // No more audio, then tell the analyser the input is over and let it finalise what it
        // already heard — the end of the last phrase.
        await capture.stop()
        // ITS OWN consumer, not everyone's: `clear()` here also silenced the meeting-audio
        // recorder, which outlives the engine's session by design.
        audioSink.remove(converter)
        converter.detach()
        inputContinuation?.finish(); inputContinuation = nil
        if let analyzer, !isFinished {
            let finalizing = Task { _ = try? await analyzer.finalizeAndFinishThroughEndOfInput() }
            if await !TaskCompletion.wait(for: finalizing, upToMs: Self.finalizeBudgetMs) {
                logger.warning("[SpeechAnalyzer] finalisation did not finish in time; cancelling")
                let cancelling = Task { await analyzer.cancelAndFinishNow() }
                await TaskCompletion.wait(for: cancelling, upToMs: Self.finalizeBudgetMs)
            }
            await TaskCompletion.wait(for: resultsTask, upToMs: Self.resultsDrainBudgetMs)
        }

        isFinished = true
        resultsTask?.cancel(); resultsTask = nil
        continuation?.finish(); continuation = nil
        analyzer = nil
        await sessionCoordinator.stopObserving()
        await sessionCoordinator.deactivate()
    }

    /// A stop arrived while `start()` was suspended: undo what start had done.
    func abandonStart() async {
        logger.warning("[SpeechAnalyzer] stop arrived while starting — capture abandoned")
        isFinished = true
        pacerTask?.cancel(); pacerTask = nil
        await capture.stop()
        audioSink.remove(converter)
        converter.detach()
        inputContinuation?.finish(); inputContinuation = nil
        if let analyzer {
            let cancelling = Task { await analyzer.cancelAndFinishNow() }
            await TaskCompletion.wait(for: cancelling, upToMs: Self.finalizeBudgetMs)
        }
        analyzer = nil
        continuation?.finish(); continuation = nil
        await sessionCoordinator.stopObserving()
        await sessionCoordinator.deactivate()
    }

    // MARK: - Finalisation pacing

    nonisolated static var pacerTickMs: Int { 100 }

    /// Asks the analyser to finalise at the speaker's pauses, so phrases and their translation
    /// arrive within a second or two instead of in 20-second blocks (see `FinalizationPacer`).
    func startFinalizationPacer() {
        pacerTask?.cancel()
        let ordinal = sessionOrdinal
        pacerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pacerTickMs) * 1_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.pacerTick(ordinal: ordinal)
            }
        }
    }

    private func pacerTick(ordinal: Int) async {
        guard ordinal == sessionOrdinal, !isFinished, !isStopping, !isSuspended, let analyzer else { return }
        guard let reason = pacer.tick(elapsedMs: Self.pacerTickMs,
                                      hasPendingGuess: transcript.hasPendingGuess,
                                      level: levelMonitor.reading().level) else { return }
        telemetry.analyzerFinalize(sessionId, reason: reason.rawValue)
        do {
            try await analyzer.finalize(through: nil)
        } catch {
            let nsError = error as NSError
            logger.error("[SpeechAnalyzer] finalize failed: \(nsError.domain, privacy: .public)/\(nsError.code)")
        }
    }

    // MARK: - Audio system events

    func startResilienceLoop() {
        resilienceTask?.cancel()
        let events = sessionCoordinator.eventStream()
        resilienceTask = Task { [weak self] in
            for await event in events {
                guard let self, await !self.isFinished else { return }
                await self.handle(event)
            }
        }
    }

    private func handle(_ event: AudioSessionEvent) async {
        guard !isFinished, !isStopping else { return }
        switch event {
        case .interrupted(let reason):
            guard !isSuspended else { return }
            isSuspended = true
            logger.warning("[SpeechAnalyzer] suspended by \(reason.rawValue, privacy: .public)")
            await capture.stop()
            await sessionCoordinator.noteSuspended(reason: reason)

        case .resumed:
            guard isSuspended else { return }
            isSuspended = false
            await sessionCoordinator.noteResumed()
            do {
                try await sessionCoordinator.activate()
                // The analyser was only waiting for audio; nothing to rebuild on its side.
                try await capture.start(sessionId: sessionId)
                logger.info("[SpeechAnalyzer] resumed after interruption")
            } catch {
                logger.error("[SpeechAnalyzer] resume failed: \(error.localizedDescription, privacy: .public)")
                isSuspended = true
                await sessionCoordinator.noteSuspended(reason: .systemInterruption)
            }

        case .captureNeedsRebuild(let reason):
            do {
                if reason == .mediaServicesReset { try await sessionCoordinator.activate() }
                // The converter follows the new input format by itself.
                try await capture.rebuildCapture(reason: reason)
            } catch {
                logger.error("[SpeechAnalyzer] rebuild failed: \(error.localizedDescription, privacy: .public)")
                isSuspended = true
                await capture.stop()
                await sessionCoordinator.noteSuspended(reason: reason)
            }

        case .giveUp(let afterMs):
            telemetry.sessionEnd(sessionId, reason: .interruption, errorDomain: "AudioSession", errorCode: -1,
                                 durationMs: afterMs, restartIndex: 0)
            isFinished = true
            continuation?.finish(); continuation = nil
        }
    }
}
