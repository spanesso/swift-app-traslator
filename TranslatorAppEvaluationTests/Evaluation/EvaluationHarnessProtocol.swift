//
//  EvaluationHarnessProtocol.swift
//  TranslatorAppEvaluationTests
//

import Foundation
@testable import TranslatorApp

protocol EvaluationHarnessProtocol: Sendable {
    /// Run the full live pipeline against every item in `manifest`.
    /// Uses the same code paths as the shipping app — no mocks.
    func run(manifest: EvaluationCorpusManifest,
             engine: any SpeechEngineProtocol,
             corrector: (any TranscriptCorrectorProtocol)?,
             buildId: String) async throws -> EvaluationReport

    /// Compare two reports against all SC gates.
    func compare(baseline: EvaluationReport,
                 candidate: EvaluationReport) -> EvaluationDelta

    /// SC-009: run twice on the same manifest; headline WER must agree within epsilon.
    func verifyReproducibility(manifest: EvaluationCorpusManifest,
                               engine: any SpeechEngineProtocol,
                               corrector: (any TranscriptCorrectorProtocol)?,
                               epsilon: Double) async throws -> Bool
}
