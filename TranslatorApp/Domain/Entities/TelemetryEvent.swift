//
//  TelemetryEvent.swift
//  TranslatorApp
//
//  Structured pipeline telemetry (008-fix-audio-pipeline-resilience, US1).
//
//  Pure Domain: only Foundation. Errors travel as (domain, code) pairs rather than NSError so
//  this layer never imports a framework — see plan.md gate G2.
//
//  Wire format is one line per event: a stable UPPERCASE type prefix followed by key=value
//  pairs (research.md §R7). The prefix makes every event type greppable with a single search,
//  which is what makes the "root cause in ≤5 minutes" target (SC-026) achievable.
//

import Foundation

/// A single structured telemetry record.
///
/// Never carries transcribed text — only counts, durations and codes. Phrase content is
/// already logged by the pre-existing `Logger` categories, whose behaviour is unchanged.
struct TelemetryEvent: Sendable {
    let kind: Kind
    let sessionId: String
    let fields: [Field]

    nonisolated init(kind: Kind, sessionId: String, fields: [Field]) {
        self.kind = kind
        self.sessionId = sessionId
        self.fields = fields
    }

    /// An ordered key=value pair. Order is stable so log lines stay diffable across runs.
    struct Field: Sendable {
        let key: String
        let value: String

        nonisolated init(_ key: String, _ value: String) {
            self.key = key
            self.value = value
        }

        nonisolated init(_ key: String, _ value: Int) {
            self.init(key, String(value))
        }

        nonisolated init(_ key: String, _ value: Bool) {
            self.init(key, value ? "true" : "false")
        }

        nonisolated init(_ key: String, _ value: Double, decimals: Int = 2) {
            self.init(key, String(format: "%.\(decimals)f", value))
        }
    }

    /// Stable event prefixes. Renaming one breaks every saved log filter, so treat these as
    /// a published interface rather than an implementation detail.
    enum Kind: String, Sendable, CaseIterable {
        // Recognition session lifecycle (FR-001, FR-002)
        case sessionStart        = "SESSION_START"
        case sessionEnd          = "SESSION_END"
        case restartBegin        = "RESTART_BEGIN"
        case restartEnd          = "RESTART_END"
        case restartFailedFatal  = "RESTART_FAILED_FATAL"
        case watchdogFired       = "WATCHDOG_FIRED"

        // Audio continuity (FR-003)
        case audioGap            = "AUDIO_GAP"
        case tapSwap             = "TAP_SWAP"
        case tapFirstBuffer      = "TAP_FIRST_BUFFER"
        case ringBufferState     = "RINGBUFFER_STATE"

        // Segmentation and endpointing (FR-004)
        case stabilityArmed      = "STAB_ARMED"
        case stabilityCancelled  = "STAB_CANCEL"
        case stabilityFired      = "STAB_FIRED"
        case pendingAge          = "PENDING_AGE"
        case asrRestartDetected  = "ASR_RESTART_DETECTED"
        case uiPrefixMismatch    = "UI_PREFIX_MISMATCH"

        // Translation queue (FR-005)
        case translationEnqueued = "TR_ENQUEUE"
        case translationStarted  = "TR_START"
        case translationDone     = "TR_DONE"
        case translationFailed   = "TR_FAILED"
        case translationSkipped  = "TR_SKIPPED"
        case translationDedup    = "TR_DEDUP_DROP"

        // Audio session (FR-006)
        case audioInterruption   = "AUDIO_INTERRUPTION"
        case audioRouteChange    = "AUDIO_ROUTE_CHANGE"
        case audioConfigChange   = "AUDIO_CONFIG_CHANGE"
        case mediaServicesReset  = "MEDIA_SERVICES_RESET"
        case audioSessionConfig  = "AUDIO_SESSION_CONFIGURED"
        case scenePhase          = "SCENE_PHASE"

        // Export (FR-033)
        case exportAlignment     = "EXPORT_ALIGNMENT"
    }

    /// Renders the single log line. `[KIND] sid=A1B2 key=value key=value`
    nonisolated var line: String {
        let body = fields.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        return body.isEmpty
            ? "[\(kind.rawValue)] sid=\(sessionId)"
            : "[\(kind.rawValue)] sid=\(sessionId) \(body)"
    }
}

// MARK: - Supporting vocabularies

enum SessionEndReason: String, Sendable {
    case isFinal, error, userStop, watchdog, interruption
}

enum RestartTrigger: String, Sendable {
    case isFinal, error, watchdog, manual, routeChange, configChange
}

enum RestartOutcome: String, Sendable { case ok, failed }

enum StabilityDelayReason: String, Sendable { case normal, lowQuality, incomplete }

/// The five points where the stability timer is cancelled. Four of them used to return without
/// rescheduling it (NLPSegmenterService, US3) — `duplicateText` being the one that caused S2.
enum StabilityCancelReason: String, Sendable {
    case newSegment, duplicateText, emptyPending, emptyTail, timeoutBranch
}

/// Which branch the live-tail reconciler took. `wordCount` recurring is the S3 signature.
enum PrefixBranch: String, Sendable { case hasPrefix, wordCount, noCommitted, restartDetected }

enum InterruptionEdge: String, Sendable { case began, ended }

/// Truncated session identifier. Four characters are enough to correlate a session's events
/// without bloating every line.
enum TelemetrySessionId {
    nonisolated static func short(_ uuid: String) -> String {
        String(uuid.prefix(4)).uppercased()
    }

    nonisolated static func new() -> String {
        short(UUID().uuidString)
    }
}
