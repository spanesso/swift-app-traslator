  Project: TranslatorApp                                                                                                                                                                                                                     
                                                                                                                                                                                                                                             
  A real-time speech-to-translation macOS app built in SwiftUI. It listens to microphone input in English, transcribes it live, and displays an offline Spanish translation side-by-side — all on-device.                                    
                                                                                                                                                                                                                                             
  ---                                                       
  Frameworks                                                                                                                                                                                                                                 
                                                            
  ┌─────────────────────────────┬─────────────────────────────────────────────────────────┐
  │          Framework          │                         Purpose                         │
  ├─────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ Speech (SFSpeechRecognizer) │ On-device ASR (Automatic Speech Recognition)            │
  ├─────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ AVFoundation                │ Audio engine and session management                     │                                                                                                                                                  
  ├─────────────────────────────┼─────────────────────────────────────────────────────────┤                                                                                                                                                  
  │ NaturalLanguage             │ NLP utilities used by the segmenter                     │                                                                                                                                                  
  ├─────────────────────────────┼─────────────────────────────────────────────────────────┤                                                                                                                                                  
  │ Translation (Apple)         │ Offline EN→ES translation via .translationTask modifier │
  ├─────────────────────────────┼─────────────────────────────────────────────────────────┤                                                                                                                                                  
  │ SwiftUI                     │ UI, @Observable, async/await integration                │
  ├─────────────────────────────┼─────────────────────────────────────────────────────────┤                                                                                                                                                  
  │ OSLog                       │ Structured logging across all layers                    │
  ├─────────────────────────────┼─────────────────────────────────────────────────────────┤                                                                                                                                                  
  │ CryptoKit                   │ Imported in NLPSegmenterService (unused currently)      │
  └─────────────────────────────┴─────────────────────────────────────────────────────────┘                                                                                                                                                  
                                                            
  ---                                                                                                                                                                                                                                        
  Architecture: Clean Architecture (3 Layers)               

  Data  ──→  Domain  ──→  Presentation
                                                                                                                                                                                                                                             
  All dependencies are wired at startup by DependencyContainer, which is owned as @State in the App entry point — no singletons, no global state.                                                                                            
                                                                                                                                                                                                                                             
  Data Layer                                                                                                                                                                                                                                 
                                                            
  - ContinuousSpeechListener (actor) — manages AVAudioEngine + SFSpeechRecognizer, emits an AsyncStream<SpeechSegment> of partial/final results, and records quality signals on each update.                                                 
  - SpeechRepository — thin protocol adapter over the listener.
                                                                                                                                                                                                                                             
  Domain Layer                                              

  - TranscribeAudioUseCase — orchestrates two phases: raw stream from ASR and segmented stream of stable phrases.                                                                                                                            
  - NLPSegmenterService — the core of the pipeline. Waits 1.4 s for ASR to stabilize, then emits only the delta (new content since last emission) if it's ≥ 5 words or ends with a period. This prevents the translation engine from
  receiving noisy micro-fragments.                                                                                                                                                                                                           
  - QualityMetricsService (actor) — tracks per-session signals: revision rate, ASR confidence, words-per-second, stability delay, and fragmentation score. Exposes isLowQualitySpeech() for potential adaptive strategies.
                                                                                                                                                                                                                                             
  Presentation Layer                                        

  - TranscriptionViewModel (@Observable, @MainActor) — runs two concurrent Tasks: one streams raw EN text to the UI, the other feeds stable phrases into translationRequests: AsyncStream<String>.                                           
  - LiveTranscriptionView — split-pane layout (35% EN / 60% ES), uses Apple's .translationTask modifier to consume the phrase stream and call back appendTranslation. Both panes auto-scroll as text arrives.
  - RecordButton — standalone toggle component.                                                                                                                                                                                              
                                                            
  ---                                                                                                                                                                                                                                        
  Main Features                                             
               
  1. Live transcription — partial ASR results update the EN pane in real time as the user speaks.
  2. Differential segmentation — only genuinely new speech chunks are sent for translation, avoiding repeated or fragmented context.                                                                                                         
  3. Offline translation — Apple's Translation framework handles EN→ES entirely on-device; no network calls or API keys required.                                                                                                            
  4. Quality metrics — silent runtime tracking of ASR quality (confidence, fragmentation, revision rate) as groundwork for adaptive segmentation tuning.                                                                                     
  5. Duplicate guard — the ViewModel drops any translated sentence that is identical to or contained within the previously appended one.                                                                                                     
  6. Translation engine lifecycle — on stop, the translation session is torn down cleanly; on next record start, SwiftUI is forced to recreate the .translationTask via an .id(UUID()) reset.                                                
                                                                                                                                                                                                                                             
  ---                                                                                                                                                                                                                                        
  What's Missing / Future Work Signals                                                                                                                                                                                                       
                                                                                                                                                                                                                                             
  - QualityMetricsService.isLowQualitySpeech() is computed but never acted upon — it exists as infrastructure for adaptive baseStabilityDelay tuning.
  - CryptoKit is imported but unused — likely planned for phrase deduplication via hashing.                                                                                                                                                  
  - The UI hardcodes en-US → es-ES; no language-picker exists yet.                                                                                                                                                                           
  - UI tests (TranslatorAppUITests) exist as scaffolding but contain no real test logic.
