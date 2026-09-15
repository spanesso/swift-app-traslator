//
//  SpeechAnalyzerMigrationTests.swift
//  TranslatorAppTests
//
//  The parts of the SpeechAnalyzer migration that do not need the real recogniser (the simulator
//  has no SpeechTranscriber): turning its results into the pipeline's text, and choosing an engine
//  without ever leaving the user unable to record.
//

import XCTest
@testable import TranslatorApp

// MARK: - Accumulating SpeechTranscriber results

final class AnalyzerTranscriptAccumulatorTests: XCTestCase {

    func testVolatileTextIsReplacedAndFinalTextIsKept() {
        var accumulator = AnalyzerTranscriptAccumulator()
        XCTAssertEqual(accumulator.apply(text: "hello", isFinal: false).text, "hello")
        XCTAssertEqual(accumulator.apply(text: "hello there", isFinal: false).text, "hello there")
        XCTAssertEqual(accumulator.apply(text: "Hello there.", isFinal: true).text, "Hello there.")
        XCTAssertEqual(accumulator.apply(text: "how", isFinal: false).text, "Hello there. how")
        XCTAssertEqual(accumulator.apply(text: "How are you?", isFinal: true).text, "Hello there. How are you?")
    }

    /// The text only grows: a new speaker's words are appended, never a reason to start over.
    func testAChangeOfSpeakerDoesNotResetTheText() {
        var accumulator = AnalyzerTranscriptAccumulator()
        _ = accumulator.apply(text: "Okay, let us go.", isFinal: true)
        let update = accumulator.apply(text: "yes I think we should", isFinal: false)
        XCTAssertEqual(update.text, "Okay, let us go. yes I think we should")
        XCTAssertEqual(update.generation, 0)
    }

    /// A long meeting starts over deliberately — after a final, with a new generation — so the
    /// text the pipeline copies on every update stays bounded.
    func testRolloverHappensOnlyAfterAFinalWithANewGeneration() {
        var accumulator = AnalyzerTranscriptAccumulator(rolloverWords: 4)
        XCTAssertEqual(accumulator.apply(text: "one two three", isFinal: false).generation, 0)
        let final = accumulator.apply(text: "one two three four.", isFinal: true)
        XCTAssertEqual(final.text, "one two three four.")
        XCTAssertEqual(final.generation, 0)
        let next = accumulator.apply(text: "five", isFinal: false)
        XCTAssertEqual(next.text, "five")
        XCTAssertEqual(next.generation, 1)
    }

    /// Field screenshot 2026-09-15: "...... She remembered it was a tin bucket.", ". That's my son's
    /// name." and a lone "." shown as too short to translate. Asked to finalise, the recogniser can
    /// return a final with no words — only punctuation — which was glued to the next phrase.
    func testPunctuationOnlyFinalsAreNotKept() {
        var accumulator = AnalyzerTranscriptAccumulator()
        _ = accumulator.apply(text: "and he took all the hot water, Daniel.", isFinal: true)
        _ = accumulator.apply(text: "......", isFinal: true)
        let update = accumulator.apply(text: "She remembered it was a tin bucket.", isFinal: true)
        XCTAssertEqual(update.finalizedText,
                       "and he took all the hot water, Daniel. She remembered it was a tin bucket.")
    }

    func testPunctuationBeforeTheFirstWordIsDropped() {
        var accumulator = AnalyzerTranscriptAccumulator()
        _ = accumulator.apply(text: "I think her father's name was Freddy.", isFinal: true)
        let update = accumulator.apply(text: ". That's my son's name.", isFinal: true)
        XCTAssertEqual(update.finalizedText, "I think her father's name was Freddy. That's my son's name.")
    }

    /// A punctuation-only final is not new text, so it must not be emitted as a phrase either.
    func testPunctuationOnlyFinalDoesNotCountAsFinalizedText() {
        var accumulator = AnalyzerTranscriptAccumulator()
        _ = accumulator.apply(text: "Oh, God.", isFinal: true)
        XCTAssertFalse(accumulator.apply(text: ".", isFinal: true).didFinalize)
    }

    /// Phrases are built from finalised text only: a volatile guess is never part of it, and only
    /// a final result marks new finalised text.
    func testFinalizedTextNeverContainsVolatileGuesses() {
        var accumulator = AnalyzerTranscriptAccumulator()
        let guess = accumulator.apply(text: "we will meet on tuesday", isFinal: false)
        XCTAssertEqual(guess.finalizedText, "")
        XCTAssertFalse(guess.didFinalize)

        let final = accumulator.apply(text: "We will meet on Thursday.", isFinal: true)
        XCTAssertEqual(final.finalizedText, "We will meet on Thursday.")
        XCTAssertTrue(final.didFinalize)

        let nextGuess = accumulator.apply(text: "and then we", isFinal: false)
        XCTAssertEqual(nextGuess.finalizedText, "We will meet on Thursday.")
        XCTAssertEqual(nextGuess.text, "We will meet on Thursday. and then we")
        XCTAssertFalse(nextGuess.didFinalize)
    }
}

// MARK: - Finalisation pacing

final class FinalizationPacerTests: XCTestCase {

    /// A pause after words: finalise, so the phrase and its translation arrive now.
    func testAPauseWithAPendingGuessAsksForFinalisation() {
        var pacer = FinalizationPacer()
        XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.6))
        for _ in 0..<4 { XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.1)) }
        XCTAssertEqual(pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.1), .pause)
    }

    /// The gap between two words is not a pause.
    func testShortGapsBetweenWordsDoNotFinalise() {
        var pacer = FinalizationPacer()
        for _ in 0..<20 {
            XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.1))
            XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.1))
            XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.6))
            if pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.6) == .longUtterance { return }
        }
    }

    /// Someone who never pauses still gets phrases.
    func testContinuousSpeechIsFinalisedAfterTheLongestWait() {
        var pacer = FinalizationPacer()
        var reason: FinalizationPacer.Reason?
        var elapsed = 0
        while reason == nil, elapsed <= FinalizationPacer.maxPendingMs {
            reason = pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.7)
            elapsed += 100
        }
        XCTAssertEqual(reason, .longUtterance)
        XCTAssertEqual(elapsed, FinalizationPacer.maxPendingMs)
    }

    /// Field log 2026-09-15: 6 of 7 finalisations were forced (longUtterance) and only one was a
    /// pause. In that room the background never went below the fixed -45 dBFS floor, so a pause
    /// between phrases was never seen. A pause is quiet RELATIVE to the room.
    func testAPauseIsDetectedInANoisyRoom() {
        var pacer = FinalizationPacer()
        // The room's background, before anyone talks.
        for _ in 0..<30 { XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: false, level: 0.40)) }
        // Someone speaks...
        for _ in 0..<10 { XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.72)) }
        // ...and pauses, back to the room's background.
        var reason: FinalizationPacer.Reason?
        for _ in 0..<8 where reason == nil {
            reason = pacer.tick(elapsedMs: 100, hasPendingGuess: true, level: 0.41)
        }
        XCTAssertEqual(reason, .pause, "a pause against the room's own background must be recognised")
    }

    /// Silence with nothing pending is just silence.
    func testNothingPendingNeverFinalises() {
        var pacer = FinalizationPacer()
        for _ in 0..<100 { XCTAssertNil(pacer.tick(elapsedMs: 100, hasPendingGuess: false, level: 0)) }
    }
}

// MARK: - Engine selection

private actor FakeEngine: SpeechEngineProtocol {
    enum Behaviour: Sendable { case succeed, fail(SpeechEngineError), cancel }

    nonisolated let engineId: EngineId
    private let behaviour: Behaviour
    private let startDelayMs: Int
    private(set) var starts = 0
    private(set) var stops = 0

    init(id: EngineId, behaviour: Behaviour, startDelayMs: Int = 0) {
        self.engineId = id
        self.behaviour = behaviour
        self.startDelayMs = startDelayMs
    }

    func start(options: SpeechEngineOptions) async throws -> AsyncStream<SpeechSegment> {
        starts += 1
        if startDelayMs > 0 { try? await Task.sleep(nanoseconds: UInt64(startDelayMs) * 1_000_000) }
        switch behaviour {
        case .succeed:        return AsyncStream { _ in }
        case .fail(let error): throw error
        case .cancel:          throw CancellationError()
        }
    }

    func stop() async { stops += 1 }
}

final class SelectingSpeechEngineTests: XCTestCase {

    private func makeSelector(preferred: FakeEngine, fallback: FakeEngine, usePreferred: Bool = true) -> SelectingSpeechEngine {
        SelectingSpeechEngine(preferred: preferred, preferredId: .appleSpeechAnalyzer,
                              fallback: fallback, fallbackId: .legacyAppleSFSpeech,
                              usePreferred: { usePreferred },
                              telemetry: NoopPipelineTelemetry())
    }

    func testSpeechAnalyzerIsUsedWhenItStarts() async throws {
        let analyzer = FakeEngine(id: .appleSpeechAnalyzer, behaviour: .succeed)
        let classic = FakeEngine(id: .legacyAppleSFSpeech, behaviour: .succeed)
        let selector = makeSelector(preferred: analyzer, fallback: classic)

        _ = try await selector.start(options: SpeechEngineOptions())
        XCTAssertEqual(selector.engineId, .appleSpeechAnalyzer)
        let classicStarts = await classic.starts
        XCTAssertEqual(classicStarts, 0)
    }

    /// A model that cannot be downloaded, an unsupported device, any failure to start: the user
    /// records anyway, with the classic recogniser.
    func testRecordingFallsBackToTheClassicRecogniserWhenSpeechAnalyzerCannotStart() async throws {
        let analyzer = FakeEngine(id: .appleSpeechAnalyzer, behaviour: .fail(.modelUnavailable))
        let classic = FakeEngine(id: .legacyAppleSFSpeech, behaviour: .succeed)
        let selector = makeSelector(preferred: analyzer, fallback: classic)

        _ = try await selector.start(options: SpeechEngineOptions())
        XCTAssertEqual(selector.engineId, .legacyAppleSFSpeech)
        let classicStarts = await classic.starts
        XCTAssertEqual(classicStarts, 1)
    }

    func testMissingPermissionIsReportedNotHiddenByAFallback() async {
        let analyzer = FakeEngine(id: .appleSpeechAnalyzer, behaviour: .fail(.notAuthorized))
        let classic = FakeEngine(id: .legacyAppleSFSpeech, behaviour: .succeed)
        let selector = makeSelector(preferred: analyzer, fallback: classic)

        do {
            _ = try await selector.start(options: SpeechEngineOptions())
            XCTFail("a permission problem must reach the user")
        } catch {
            XCTAssertEqual(error as? SpeechEngineError, .notAuthorized)
        }
        let classicStarts = await classic.starts
        XCTAssertEqual(classicStarts, 0)
    }

    /// A stop during start must not turn into "start the other engine".
    func testAStopDuringStartIsNotTurnedIntoAFallback() async {
        let analyzer = FakeEngine(id: .appleSpeechAnalyzer, behaviour: .cancel)
        let classic = FakeEngine(id: .legacyAppleSFSpeech, behaviour: .succeed)
        let selector = makeSelector(preferred: analyzer, fallback: classic)

        _ = try? await selector.start(options: SpeechEngineOptions())
        let classicStarts = await classic.starts
        XCTAssertEqual(classicStarts, 0)
    }

    /// The stop must reach the engine that is still starting, or its capture outlives the stop.
    func testStopReachesTheEngineThatIsStillStarting() async {
        let analyzer = FakeEngine(id: .appleSpeechAnalyzer, behaviour: .succeed, startDelayMs: 300)
        let classic = FakeEngine(id: .legacyAppleSFSpeech, behaviour: .succeed)
        let selector = makeSelector(preferred: analyzer, fallback: classic)

        let starting = Task { _ = try? await selector.start(options: SpeechEngineOptions()) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        await selector.stop()
        _ = await starting.value

        let stops = await analyzer.stops
        XCTAssertEqual(stops, 1)
    }

    func testTheClassicPreferenceSkipsSpeechAnalyzer() async throws {
        let analyzer = FakeEngine(id: .appleSpeechAnalyzer, behaviour: .succeed)
        let classic = FakeEngine(id: .legacyAppleSFSpeech, behaviour: .succeed)
        let selector = makeSelector(preferred: analyzer, fallback: classic, usePreferred: false)

        _ = try await selector.start(options: SpeechEngineOptions())
        let analyzerStarts = await analyzer.starts
        XCTAssertEqual(analyzerStarts, 0)
        XCTAssertEqual(selector.engineId, .legacyAppleSFSpeech)
        XCTAssertFalse(EnginePreference.appleOnly.usesSpeechAnalyzer)
        XCTAssertTrue(EnginePreference.auto.usesSpeechAnalyzer)
    }
}
