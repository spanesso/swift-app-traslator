//
//  ModelDownloadCoordinatorProtocol.swift
//  TranslatorApp — feature 005-accent-robust-asr
//
//  Domain contract for the WhisperKit model installation lifecycle.
//  The concrete implementation wraps Apple's BackgroundAssets framework
//  (Apple-blessed pattern for on-device ML packs).
//

import Foundation

protocol ModelDownloadCoordinatorProtocol: Sendable {
    /// Current state. Observable via the published stream below.
    var currentState: ModelInstallState { get async }

    /// Push stream of state changes. New subscribers receive the current state on subscribe.
    func stateStream() -> AsyncStream<ModelInstallState>

    /// User accepted the download. Coordinator transitions:
    ///   awaitingConsent  →  downloading(0.0) → ... → installed(...) | failed(reason)
    func acceptDownload() async

    /// User declined. Terminal until `retryRequest()` is called.
    func declineDownload() async

    /// User reopened from settings — re-arm the consent prompt.
    /// declined | failed → awaitingConsent
    func retryRequest() async

    /// Engineering-side hook used by the harness to swap in a fake state.
    /// Production callers do not invoke this.
    func _forceState(_ state: ModelInstallState) async
}
