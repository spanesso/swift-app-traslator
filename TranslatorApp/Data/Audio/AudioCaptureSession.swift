//
//  AudioCaptureSession.swift
//  TranslatorApp
//
//  Owner of AVAudioEngine and of the microphone tap
//  (008-fix-audio-pipeline-resilience, US6 / research §R4).
//
//  THE CENTRAL RULE
//  The tap is installed ONCE per recording session. Recogniser rotation never touches it — that
//  is a pointer swap inside `RecognitionRequestBox`. The tap is rebuilt only for the one thing
//  that genuinely requires it: a route or configuration change, which alters the input node's
//  format.
//
//  The previous design had this backwards: it rebuilt the tap on every rotation (frequent) in
//  order to cope with format changes (rare), paying the cost of the common case to handle the
//  uncommon one — and it read the input format once and reused it forever, so it did not
//  actually handle the uncommon case either.
//
//  Periodic reporting (carry-over window, stalls, resources) lives in
//  AudioCaptureSession+Reporting.swift.
//

import AVFoundation
import OSLog
import os

actor AudioCaptureSession {

    let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "AudioCapture")
    let telemetry: any PipelineTelemetryProtocol
    private let requestBox: RecognitionRequestBox
    let ringBuffer: AudioRingBuffer
    private let levelMonitor: AudioLevelMonitor

    /// A `var`: after a media services reset every audio object built before it is dead, and a tap
    /// re-installed on the old engine can "start" without a single buffer ever arriving
    /// (research 2026-09-15, A3).
    var audioEngine = AVAudioEngine()
    private var isTapInstalled = false
    var sessionId = "----"
    var reportTask: Task<Void, Never>?
    /// The format the tap was actually installed with — reported, never assumed.
    private(set) var tapFormat: AVAudioFormat?

    // Owned by AudioCaptureSession+Reporting.swift.
    var stallDetector = TapStallDetector()
    var lastThermalState: ProcessInfo.ThermalState?
    var ticksSinceResourceReport = 0

    /// Written from the audio render thread, read from the actor. Lock-protected rather than
    /// actor-isolated for the same reason as `RecognitionRequestBox`.
    let tapStats = OSAllocatedUnfairLock(initialState: TapStats())

    struct TapStats {
        var lastSampleTime: AVAudioFramePosition?
        var sampleRate: Double = 0
        var buffersSinceReport: Int = 0
        var firstBufferSeen = false
    }

    /// What one buffer revealed, handed out of the lock so telemetry is emitted outside it.
    nonisolated struct TapObservation: Sendable {
        var firstBufferAfterMs: Int?
        var gapMs: Int?
        var expectedMs = 0
        var frames = 0
        var rate = 0.0
    }

    init(telemetry: any PipelineTelemetryProtocol,
         requestBox: RecognitionRequestBox,
         ringBuffer: AudioRingBuffer,
         levelMonitor: AudioLevelMonitor) {
        self.telemetry = telemetry
        self.requestBox = requestBox
        self.ringBuffer = ringBuffer
        self.levelMonitor = levelMonitor
    }

    // MARK: - Lifecycle

    /// Starts capture and installs the tap. Idempotent: calling it twice does not reinstall.
    func start(sessionId: String) throws {
        self.sessionId = sessionId
        guard !isTapInstalled else { return }
        try installTapAndStart(restartIndex: 0)
        startPeriodicReporting()
    }

    func stop() {
        reportTask?.cancel(); reportTask = nil
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        ringBuffer.reset()
        levelMonitor.reset()
        resetTapStats()
        logger.info("[AudioCapture] stopped")
    }

    /// Rebuilds capture with the CURRENT input format. The only path that legitimately touches
    /// the tap. Budgeted at `ResumePolicy.rebuildBudgetMs` (SC-008).
    ///
    /// Reading `outputFormat(forBus:)` here, at install time, is the whole point: the previous
    /// implementation cached the format from the first start and reused it after every route
    /// change, so the tap silently stopped delivering buffers when headphones were connected.
    func rebuildCapture(reason: AudioInterruptionReason) throws {
        let startedAt = MonotonicClock.now()
        let previousFormat = tapFormat

        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        if reason == .mediaServicesReset {
            audioEngine = AVAudioEngine()
        }
        resetTapStats()
        try installTapAndStart(restartIndex: -1)

        // The hardware side against what the tap was installed with. `formatsMatch` used to be
        // hardcoded to true, and both formats were the same variable.
        let hardwareFormat = audioEngine.inputNode.inputFormat(forBus: 0)
        telemetry.audioConfigChange(sessionId,
                                    engineIsRunning: audioEngine.isRunning,
                                    inputFormat: Self.describe(hardwareFormat),
                                    tapFormat: tapFormat.map(Self.describe) ?? "-",
                                    formatsMatch: tapFormat.map { Self.sameShape($0, hardwareFormat) } ?? false)
        logger.info("""
            [AudioCapture] rebuilt after \(reason.rawValue, privacy: .public) in \
            \(MonotonicClock.msSince(startedAt))ms \
            \(previousFormat.map(Self.describe) ?? "-", privacy: .public) → \
            \(self.tapFormat.map(Self.describe) ?? "-", privacy: .public)
            """)
    }

    var isRunning: Bool { audioEngine.isRunning }

    /// Current input format, for diagnostics.
    var currentFormatDescription: String {
        Self.describe(audioEngine.inputNode.outputFormat(forBus: 0))
    }

    // MARK: - Tap

    private func installTapAndStart(restartIndex: Int) throws {
        let inputNode = audioEngine.inputNode
        // Read the format NOW, never from a cached value.
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            logger.error("[AudioCapture] invalid input format \(Self.describe(format), privacy: .public)")
            throw SpeechEngineError.engineConfigurationFailed
        }

        tapStats.withLock { $0.sampleRate = format.sampleRate }

        let installedAt = MonotonicClock.now()
        let box = requestBox
        let ring = ringBuffer
        let level = levelMonitor
        let stats = tapStats
        let sink = telemetry
        let sid = sessionId

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            // Audio thread. No allocation, no await, no logging on the fast path.
            box.append(buffer, recordingInto: ring)

            // Input level, so a speaker the recogniser cannot hear stops being invisible.
            // Arithmetic only — no allocation on the render thread.
            if let channel = buffer.floatChannelData?[0] {
                level.record(samples: channel, count: Int(buffer.frameLength))
            }

            let observation = stats.withLock { state -> TapObservation in
                var observation = TapObservation()
                state.buffersSinceReport += 1
                // Measured when the first buffer ARRIVES. This used to be emitted right after
                // `start()`, before any buffer existed, so it could never reveal a dead tap.
                if !state.firstBufferSeen {
                    state.firstBufferSeen = true
                    observation.firstBufferAfterMs = MonotonicClock.msSince(installedAt)
                }
                let previousEnd = state.lastSampleTime
                state.lastSampleTime = when.sampleTime + AVAudioFramePosition(buffer.frameLength)
                guard state.sampleRate > 0, let previousEnd else { return observation }
                let missing = when.sampleTime - previousEnd
                guard missing > 0 else { return observation }
                let gapMs = Int(Double(missing) / state.sampleRate * 1000.0)
                let expectedMs = Int(Double(buffer.frameLength) / state.sampleRate * 1000.0)
                // Only report gaps beyond twice the nominal buffer duration; a line per
                // buffer would flood the trace and defeat the point of the log.
                guard gapMs > expectedMs * 2 else { return observation }
                observation.gapMs = gapMs
                observation.expectedMs = expectedMs
                observation.frames = Int(buffer.frameLength)
                observation.rate = state.sampleRate
                return observation
            }

            if let firstBufferAfterMs = observation.firstBufferAfterMs {
                sink.tapFirstBuffer(sid, restartIndex: restartIndex, msSinceInstall: firstBufferAfterMs)
            }
            if let gapMs = observation.gapMs {
                sink.audioGap(sid,
                              gapMs: gapMs,
                              expectedMs: observation.expectedMs,
                              bufferFrames: observation.frames,
                              sampleRate: observation.rate)
            }
        }

        tapFormat = format
        isTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()

        logger.info("""
            [AudioCapture] tap installed fmt=\(Self.describe(format), privacy: .public) \
            running=\(self.audioEngine.isRunning)
            """)
    }

    private func resetTapStats() {
        tapStats.withLock { state in
            state.lastSampleTime = nil
            state.buffersSinceReport = 0
            state.firstBufferSeen = false
        }
        stallDetector.reset()
    }
}
