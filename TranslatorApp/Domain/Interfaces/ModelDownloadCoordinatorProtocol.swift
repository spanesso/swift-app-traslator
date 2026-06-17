//
//  ModelDownloadCoordinatorProtocol.swift
//  TranslatorApp
//
//  Domain contract for the WhisperKit model download lifecycle.
//  The concrete implementation wraps Apple's BackgroundAssets framework.

import Foundation

protocol ModelDownloadCoordinatorProtocol: Sendable {
    var currentState: ModelInstallState { get async }
    func stateStream() -> AsyncStream<ModelInstallState>
    func acceptDownload() async
    func declineDownload() async
    /// Re-arms the consent prompt after a declined or failed download.
    func retryRequest() async
    /// Engineering hook for the evaluation harness to inject a fake state.
    func _forceState(_ state: ModelInstallState) async
}
