//
//  AudioSessionCoordinator.swift
//  TranslatorApp
//
//  Single owner of AVAudioSession and of every audio system notification
//  (008-fix-audio-pipeline-resilience, US5).
//
//  WHAT THIS REPLACES
//  Three engines each configured the session independently and inconsistently, plus one loose
//  observer in the composition root that listened only for the START of an interruption, was
//  never removed, and reacted by killing the recording and showing a permissions error.
//  Route changes, configuration changes and media-services resets were not observed at all.
//
//  THE UNATTENDED CASE (the requirement that drove this design)
//  An alarm that rings itself out, or a call nobody answers, must not end the session. iOS does
//  not reliably deliver the end-of-interruption notification, so waiting for it reproduces the
//  same failure in a new shape. Instead, while suspended, the coordinator retries
//  `setActive(true)` on a timer: a successful reactivation IS the observable proof that the
//  interruption is over (research §R2).
//

import AVFoundation
import OSLog

actor AudioSessionCoordinator: AudioSessionCoordinatorProtocol {

    let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "AudioSession")
    let telemetry: any PipelineTelemetryProtocol
    var sessionId = "----"

    private var continuations: [UUID: AsyncStream<AudioSessionEvent>.Continuation] = [:]
    private var observerTokens: [NSObjectProtocol] = []
    var pollTask: Task<Void, Never>?
    var suspendedSince: ContinuousClock.Instant?
    var isActive = false
    /// When we last called `setActive(true)`. Route and configuration notifications that arrive
    /// right after are echoes of our own call, not something the user did.
    var lastActivationAt: ContinuousClock.Instant?

    init(telemetry: any PipelineTelemetryProtocol) {
        self.telemetry = telemetry
    }

    func setSessionId(_ id: String) { sessionId = id }

    // MARK: - Event stream

    nonisolated func eventStream() -> AsyncStream<AudioSessionEvent> {
        AsyncStream { continuation in
            let id = UUID()
            Task { await self.register(continuation, id: id) }
            continuation.onTermination = { [weak self] _ in
                Task { await self?.unregister(id: id) }
            }
        }
    }

    private func register(_ continuation: AsyncStream<AudioSessionEvent>.Continuation, id: UUID) {
        continuations[id] = continuation
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
    }

    func publish(_ event: AudioSessionEvent) {
        for continuation in continuations.values { continuation.yield(event) }
    }

    // MARK: - Session lifecycle

    func activate() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            // One place, one configuration, for every engine (FR-022). `.default` rather than
            // `.measurement`: it keeps the system's automatic gain control and noise reduction,
            // which feature 005 identified as critical for accented, distant or quiet speech.
            try session.setCategory(.record, mode: .default, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            logger.error("[AudioSession] activation failed: \(error.localizedDescription, privacy: .public)")
            throw SpeechEngineError.engineConfigurationFailed
        }
        isActive = true
        lastActivationAt = MonotonicClock.now()
        telemetry.audioSessionConfigured(sessionId,
                                         category: AudioSessionConfig.categoryName,
                                         mode: AudioSessionConfig.modeName,
                                         options: AudioSessionConfig.optionsName,
                                         sampleRate: session.sampleRate,
                                         ioBufferDurationMs: session.ioBufferDuration * 1000,
                                         inputChannels: session.inputNumberOfChannels)
    }

    /// Only on a real stop. Never while suspended — keeping the session active is what makes
    /// resuming possible at all (FR-030).
    func deactivate() {
        stopPolling()
        guard isActive else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        isActive = false
        logger.info("[AudioSession] deactivated")
    }

    // MARK: - Observation

    func startObserving() {
        guard observerTokens.isEmpty else { return }
        let center = NotificationCenter.default

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification, object: nil, queue: nil
        ) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt ?? 0
            let optionsRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: optionsRaw).contains(.shouldResume)
            let began = raw == AVAudioSession.InterruptionType.began.rawValue
            Task { await self?.handleInterruption(began: began, shouldResume: shouldResume) }
        })

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification, object: nil, queue: nil
        ) { [weak self] note in
            let reasonRaw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt ?? 0
            let previous = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey] as? AVAudioSessionRouteDescription
            Task { await self?.handleRouteChange(reasonRaw: reasonRaw, previousRoute: previous) }
        })

        observerTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.handleConfigurationChange() }
        })

        observerTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: nil
        ) { [weak self] _ in
            Task { await self?.handleMediaServicesReset() }
        })

        logger.info("[AudioSession] observing interruption, route, configuration and reset")
    }

    func stopObserving() {
        for token in observerTokens { NotificationCenter.default.removeObserver(token) }
        observerTokens.removeAll()
        stopPolling()
    }
}
