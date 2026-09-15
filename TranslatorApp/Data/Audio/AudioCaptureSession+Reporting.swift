//
//  AudioCaptureSession+Reporting.swift
//  TranslatorApp
//
//  Once-a-second health reporting while capture runs: the carry-over window, a tap that stopped
//  delivering audio, and the device's thermal and memory state (research 2026-09-15, phase 1).
//  Split from AudioCaptureSession.swift to keep both files under the 250-line convention.
//
//  Sampling rather than logging per buffer is deliberate: a line per buffer would bury every
//  other event in the trace.
//

import AVFoundation
import OSLog
import os

extension AudioCaptureSession {

    /// Resources are reported on every thermal change and, otherwise, this often (in ticks).
    nonisolated static var resourceReportIntervalTicks: Int { 30 }

    func startPeriodicReporting() {
        reportTask?.cancel()
        stallDetector.reset()
        lastThermalState = nil
        ticksSinceResourceReport = 0
        reportTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.reportTick()
            }
        }
    }

    private func reportTick() {
        let snapshot = ringBuffer.snapshot()
        telemetry.ringBufferState(sessionId,
                                  bufferedMs: snapshot.bufferedMs,
                                  bufferCount: snapshot.bufferCount,
                                  evicted: snapshot.evicted)
        reportStall()
        reportResources()
    }

    /// No buffers at all is not silence — silence still arrives as buffers. `AUDIO_GAP` needs a
    /// NEXT buffer to measure a gap and `RECOGNIZER_DEAF` needs speech energy, so a capture path
    /// that went dead was invisible to both.
    private func reportStall() {
        let buffers = tapStats.withLock { state -> Int in
            let count = state.buffersSinceReport
            state.buffersSinceReport = 0
            return count
        }
        guard let event = stallDetector.observe(buffers: buffers, intervalMs: 1_000) else { return }
        switch event {
        case .stalled(let silentMs):
            telemetry.tapStall(sessionId, stalled: true, silentMs: silentMs, engineRunning: audioEngine.isRunning)
            logger.error("[AudioCapture] no audio from the microphone for \(silentMs)ms (engine running=\(self.audioEngine.isRunning))")
        case .recovered(let afterMs):
            telemetry.tapStall(sessionId, stalled: false, silentMs: afterMs, engineRunning: audioEngine.isRunning)
            logger.notice("[AudioCapture] microphone audio is back after \(afterMs)ms")
        }
    }

    /// Thermal state and the memory left before the system terminates the app. Nothing measured
    /// either before, so a meeting cut short by heat or memory could not be told apart from any
    /// other failure.
    private func reportResources() {
        let thermal = ProcessInfo.processInfo.thermalState
        ticksSinceResourceReport += 1
        let changed = thermal != lastThermalState
        guard changed || ticksSinceResourceReport >= Self.resourceReportIntervalTicks else { return }
        lastThermalState = thermal
        ticksSinceResourceReport = 0
        telemetry.resources(sessionId,
                            thermal: Self.describe(thermal),
                            availableMemoryMB: Int(os_proc_available_memory() / 1_048_576),
                            reason: changed ? "thermalChange" : "periodic")
    }

    // MARK: - Formatting

    nonisolated static func describe(_ format: AVAudioFormat) -> String {
        "\(Int(format.sampleRate))Hz/\(format.channelCount)ch"
    }

    nonisolated static func sameShape(_ a: AVAudioFormat, _ b: AVAudioFormat) -> Bool {
        a.sampleRate == b.sampleRate && a.channelCount == b.channelCount
    }

    nonisolated static func describe(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal:  return "nominal"
        case .fair:     return "fair"
        case .serious:  return "serious"
        case .critical: return "critical"
        @unknown default: return "unknown"
        }
    }
}
