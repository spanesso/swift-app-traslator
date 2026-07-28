//
//  AudioSessionCoordinator+Observation.swift
//  TranslatorApp
//
//  Notification handlers and the resume machinery
//  (008-fix-audio-pipeline-resilience, US5 / research §R2).
//  Split from AudioSessionCoordinator.swift to keep both files under the 250-line convention.
//
//  The backup poll is the part that matters: iOS does not reliably deliver the
//  end-of-interruption notification, so a successful `setActive(true)` is used as the
//  observable proof that the interruption is over. That is what recovers an alarm the user
//  never touched.
//

import AVFoundation
import OSLog

extension AudioSessionCoordinator {

    func handleInterruption(began: Bool, shouldResume: Bool) {
        telemetry.audioInterruption(sessionId,
                                    edge: began ? .began : .ended,
                                    shouldResume: shouldResume,
                                    wasRecording: suspendedSince != nil || isActive)
        if began {
            logger.warning("[AudioSession] interruption began")
            publish(.interrupted(.systemInterruption))
        } else {
            // The end notification is a fast path, not the guarantee. The poll is the guarantee.
            logger.info("[AudioSession] interruption ended (shouldResume=\(shouldResume))")
            Task { await self.tryResume() }
        }
    }

    func handleRouteChange(reasonRaw: UInt, previousRoute: AVAudioSessionRouteDescription?) {
        let session = AVAudioSession.sharedInstance()
        let previousInput = previousRoute?.inputs.first
        telemetry.audioRouteChange(sessionId,
                                   reason: Self.describe(reasonRaw),
                                   previousInput: previousInput?.portName ?? "-",
                                   newInput: session.currentRoute.inputs.first?.portName ?? "-",
                                   previousSampleRate: 0,
                                   newSampleRate: session.sampleRate,
                                   previousChannels: previousRoute?.inputs.count ?? 0,
                                   newChannels: session.inputNumberOfChannels)

        // Not every route change means the microphone moved.
        //
        // `setCategory` + `setActive` — which WE call to start recording — make iOS post a
        // route change with reason `.categoryChange`. Treating that as a device change made the
        // app announce a pause to itself on every single start, while capture was in fact
        // running perfectly. Only an actual input device appearing or disappearing warrants
        // rebuilding the tap; genuine format changes arrive separately as
        // `AVAudioEngineConfigurationChange`, which is observed on its own.
        guard Self.isDeviceChange(reasonRaw) else {
            logger.debug("[AudioSession] route change ignored (\(Self.describe(reasonRaw), privacy: .public))")
            return
        }
        guard !isWithinSelfInflictedWindow else {
            logger.debug("[AudioSession] route change ignored (caused by our own activation)")
            return
        }
        logger.warning("[AudioSession] input device changed (\(Self.describe(reasonRaw), privacy: .public))")
        publish(.captureNeedsRebuild(.routeChanged))
    }

    func handleConfigurationChange() {
        guard !isWithinSelfInflictedWindow else {
            logger.debug("[AudioSession] configuration change ignored (caused by our own activation)")
            return
        }
        logger.warning("[AudioSession] engine configuration changed")
        publish(.captureNeedsRebuild(.configurationChanged))
    }

    /// True while a route or configuration change is most likely the echo of our own
    /// `activate()` rather than something the user did.
    private var isWithinSelfInflictedWindow: Bool {
        guard let activatedAt = lastActivationAt else { return false }
        return MonotonicClock.msSince(activatedAt) < Self.selfInflictedWindowMs
    }

    private nonisolated static var selfInflictedWindowMs: Int { 800 }

    /// Only these two mean the microphone itself changed. `.categoryChange` and `.override` are
    /// consequences of our own configuration; `.routeConfigurationChange` and `.wakeFromSleep`
    /// do not move the input device.
    private nonisolated static func isDeviceChange(_ raw: UInt) -> Bool {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return false }
        switch reason {
        case .newDeviceAvailable, .oldDeviceUnavailable: return true
        default:                                         return false
        }
    }

    private nonisolated static func describe(_ raw: UInt) -> String {
        guard let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return "raw\(raw)" }
        switch reason {
        case .unknown:                   return "unknown"
        case .newDeviceAvailable:        return "newDevice"
        case .oldDeviceUnavailable:      return "oldDeviceGone"
        case .categoryChange:            return "categoryChange"
        case .override:                  return "override"
        case .wakeFromSleep:             return "wakeFromSleep"
        case .noSuitableRouteForCategory: return "noSuitableRoute"
        case .routeConfigurationChange:  return "routeConfigChange"
        @unknown default:                return "raw\(raw)"
        }
    }

    func handleMediaServicesReset() {
        telemetry.mediaServicesReset(sessionId, wasRecording: isActive)
        logger.error("[AudioSession] media services were reset")
        isActive = false
        publish(.captureNeedsRebuild(.mediaServicesReset))
    }

    // MARK: - Resume machinery (research §R2)

    func noteSuspended(reason: AudioInterruptionReason) {
        guard suspendedSince == nil else { return }
        suspendedSince = MonotonicClock.now()
        // Publish so the UI learns about suspensions the engine decided on its own — a failed
        // capture rebuild, for instance. Without this the app could be silently suspended with
        // the interface still claiming it was recording.
        publish(.interrupted(reason))
        startPolling()
    }

    func noteResumed() {
        suspendedSince = nil
        stopPolling()
    }

    func attemptReactivation() async -> Bool {
        do {
            try AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
            isActive = true
            return true
        } catch {
            return false
        }
    }

    func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(ResumePolicy.pollIntervalMs) * 1_000_000)
                guard !Task.isCancelled else { return }
                if await self.pollOnce() { return }
            }
        }
    }

    /// One poll iteration. Returns true when polling should stop — either because capture
    /// resumed or because the ceiling was reached.
    func pollOnce() async -> Bool {
        guard let since = suspendedSince else { return true }
        let elapsedMs = MonotonicClock.msSince(since)
        if elapsedMs >= ResumePolicy.giveUpAfterMs {
            logger.error("[AudioSession] giving up after \(elapsedMs)ms suspended")
            suspendedSince = nil
            publish(.giveUp(afterMs: elapsedMs))
            return true
        }
        if await attemptReactivation() {
            logger.info("[AudioSession] reactivated by poll after \(elapsedMs)ms")
            suspendedSince = nil
            publish(.resumed)
            return true
        }
        return false
    }

    func tryResume() async {
        guard suspendedSince != nil else { return }
        if await attemptReactivation() {
            suspendedSince = nil
            stopPolling()
            publish(.resumed)
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}
