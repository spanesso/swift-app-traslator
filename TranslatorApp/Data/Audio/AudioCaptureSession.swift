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

import AVFoundation
import OSLog
import os

actor AudioCaptureSession {

    private let logger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "AudioCapture")
    private let telemetry: any PipelineTelemetryProtocol
    private let requestBox: RecognitionRequestBox
    private let ringBuffer: AudioRingBuffer

    private let audioEngine = AVAudioEngine()
    private var isTapInstalled = false
    private var sessionId = "----"
    private var reportTask: Task<Void, Never>?

    /// Written from the audio render thread, read from the actor. Lock-protected rather than
    /// actor-isolated for the same reason as `RecognitionRequestBox`.
    private let tapStats = OSAllocatedUnfairLock(initialState: TapStats())

    private struct TapStats {
        var lastSampleTime: AVAudioFramePosition?
        var sampleRate: Double = 0
        var buffersSinceReport: Int = 0
        var firstBufferSeen = false
    }

    init(telemetry: any PipelineTelemetryProtocol,
         requestBox: RecognitionRequestBox,
         ringBuffer: AudioRingBuffer) {
        self.telemetry = telemetry
        self.requestBox = requestBox
        self.ringBuffer = ringBuffer
    }

    // MARK: - Lifecycle

    /// Starts capture and installs the tap. Idempotent: calling it twice does not reinstall.
    func start(sessionId: String) throws {
        self.sessionId = sessionId
        guard !isTapInstalled else { return }
        try installTapAndStart(restartIndex: 0)
        startRingBufferReporting()
    }

    func stop() {
        reportTask?.cancel(); reportTask = nil
        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        ringBuffer.reset()
        resetTapStats()
        logger.info("[AudioCapture] stopped")
    }

    /// Samples the carry-over buffer once a second. Sampling rather than logging per buffer is
    /// deliberate: a line per buffer would bury every other event in the trace.
    private func startRingBufferReporting() {
        reportTask?.cancel()
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.reportRingBufferState()
            }
        }
    }

    private func reportRingBufferState() {
        let snapshot = ringBuffer.snapshot()
        telemetry.ringBufferState(sessionId,
                                  bufferedMs: snapshot.bufferedMs,
                                  bufferCount: snapshot.bufferCount,
                                  evicted: snapshot.evicted)
    }

    /// Rebuilds capture with the CURRENT input format. The only path that legitimately touches
    /// the tap. Budgeted at `ResumePolicy.rebuildBudgetMs` (SC-008).
    ///
    /// Reading `outputFormat(forBus:)` here, at install time, is the whole point: the previous
    /// implementation cached the format from the first start and reused it after every route
    /// change, so the tap silently stopped delivering buffers when headphones were connected.
    func rebuildCapture(reason: AudioInterruptionReason) throws {
        let startedAt = MonotonicClock.now()
        let previousFormat = isTapInstalled ? audioEngine.inputNode.outputFormat(forBus: 0) : nil

        audioEngine.stop()
        if isTapInstalled {
            audioEngine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        resetTapStats()
        try installTapAndStart(restartIndex: -1)

        let newFormat = audioEngine.inputNode.outputFormat(forBus: 0)
        telemetry.audioConfigChange(sessionId,
                                    engineIsRunning: audioEngine.isRunning,
                                    inputFormat: Self.describe(newFormat),
                                    tapFormat: Self.describe(newFormat),
                                    formatsMatch: true)
        logger.info("""
            [AudioCapture] rebuilt after \(reason.rawValue, privacy: .public) in \
            \(MonotonicClock.msSince(startedAt))ms \
            \(previousFormat.map(Self.describe) ?? "-", privacy: .public) → \
            \(Self.describe(newFormat), privacy: .public)
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
        let stats = tapStats
        let sink = telemetry
        let sid = sessionId

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, when in
            // Audio render thread. No allocation, no await, no logging on the fast path.
            box.append(buffer)
            ring.append(buffer)

            let report: (gapMs: Int, expectedMs: Int, frames: Int, rate: Double)? =
                stats.withLock { state -> (Int, Int, Int, Double)? in
                    defer {
                        state.lastSampleTime = when.sampleTime + AVAudioFramePosition(buffer.frameLength)
                        state.firstBufferSeen = true
                    }
                    guard state.sampleRate > 0 else { return nil }
                    guard let previousEnd = state.lastSampleTime else { return nil }
                    let missing = when.sampleTime - previousEnd
                    guard missing > 0 else { return nil }
                    let gapMs = Int(Double(missing) / state.sampleRate * 1000.0)
                    let expectedMs = Int(Double(buffer.frameLength) / state.sampleRate * 1000.0)
                    // Only report gaps beyond twice the nominal buffer duration; a line per
                    // buffer would flood the trace and defeat the point of the log.
                    guard gapMs > expectedMs * 2 else { return nil }
                    return (gapMs, expectedMs, Int(buffer.frameLength), state.sampleRate)
                }

            if let report {
                sink.audioGap(sid,
                              gapMs: report.gapMs,
                              expectedMs: report.expectedMs,
                              bufferFrames: report.frames,
                              sampleRate: report.rate)
            }
        }

        isTapInstalled = true
        audioEngine.prepare()
        try audioEngine.start()

        telemetry.tapFirstBuffer(sessionId,
                                 restartIndex: restartIndex,
                                 msSinceInstall: MonotonicClock.msSince(installedAt))
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
    }

    private static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
    }
}
