//
//  ModelDownloadCoordinatorProtocol.swift
//  TranslatorApp
//
//  Domain contract for the WhisperKit model download lifecycle.
//  The concrete implementation wraps Apple's BackgroundAssets framework.

import Foundation

protocol ModelDownloadCoordinatorProtocol: Sendable {
    var currentState: ModelInstallState { get async }
    // `async` because the conformer is an actor. Declaring it synchronously produced an
    // isolation-mismatch warning that is an error in the Swift 6 language mode (gate G5).
    func stateStream() async -> AsyncStream<ModelInstallState>
    func acceptDownload() async
    func declineDownload() async
    /// Re-arms the consent prompt after a declined or failed download.
    func retryRequest() async
    /// Engineering hook for the evaluation harness to inject a fake state.
    func _forceState(_ state: ModelInstallState) async
}
