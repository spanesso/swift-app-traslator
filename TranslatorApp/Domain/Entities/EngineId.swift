//
//  EngineId.swift
//  TranslatorApp
//

import Foundation

/// Identifies which ASR engine produced a given segment.
/// Carried on every SpeechSegment so logs and harness can attribute outcomes.
enum EngineId: String, Sendable, Codable, CaseIterable {
    case legacyAppleSFSpeech   // SFSpeechRecognizer (pre-iOS 26 fallback)
    case appleSpeechAnalyzer   // iOS 26 SpeechAnalyzer / SpeechTranscriber
    case whisperKitTurbo       // WhisperKit large-v3-turbo (compressed, Tier 1)
    case whisperKitSmall       // WhisperKit small (warm-up / fallback)
}
