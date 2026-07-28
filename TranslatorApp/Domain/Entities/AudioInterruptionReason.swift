//
//  AudioInterruptionReason.swift
//  TranslatorApp
//
//  Why audio capture stopped (008-fix-audio-pipeline-resilience, US5).
//
//  Modelled as a cause rather than a boolean because FR-029 requires the user-facing message to
//  describe what actually happened. Previously every interruption was surfaced as a permissions
//  problem, which is both wrong and unactionable.
//

import Foundation

enum AudioInterruptionReason: String, Sendable, Equatable, CaseIterable {
    /// Phone call, alarm, or voice assistant. Includes the case that matters most: an
    /// interruption the user never attends to, which must suspend the session rather than end it.
    case systemInterruption

    /// Headphones connected or disconnected. Changes the input node's format, so the tap has to
    /// be reinstalled with the NEW format — never a cached one.
    case routeChanged

    /// The audio engine's configuration changed underneath us.
    case configurationChanged

    /// Media services restarted; the whole audio graph has to be rebuilt.
    case mediaServicesReset

    /// Short, honest sentence for the UI. Never claims a permissions problem.
    nonisolated var userFacingMessage: String {
        switch self {
        case .systemInterruption:
            return "Paused by another app or a system sound. Recording resumes automatically."
        case .routeChanged:
            return "Audio device changed. Reconnecting the microphone…"
        case .configurationChanged:
            return "Audio configuration changed. Reconnecting the microphone…"
        case .mediaServicesReset:
            return "The system audio service restarted. Rebuilding the recording session…"
        }
    }

    /// Whether the app expects to recover without the user doing anything. All four currently
    /// do; the distinction exists so the UI copy can stay honest if that ever changes.
    nonisolated var recoversAutomatically: Bool { true }
}
