//
//  DependencyContainer.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import SwiftUI

/// Container que centraliza la creación de dependencias y asegura
/// que los componentes vivan el tiempo necesario (Session Lifecycle).
final class DependencyContainer {
    
    // 1. Data Layer (Instancias únicas para la sesión)
    private let speechListener: ContinuousSpeechListener
    private let speechRepository: SpeechRepositoryProtocol
    
    // 2. Domain Layer (Servicios de lógica de negocio)
    private let nlpSegmenter: NLPSegmenterServiceProtocol
    
    // /CAMBIO/ 3. Quality Metrics Service
    private let qualityMetrics: QualityMetricsService
    
    // 3. Use Cases (Orquestadores)
    private let transcribeUseCase: TranscribeAudioUseCase
    
    init() {
        // /CAMBIO/ Inicializamos el servicio de métricas de calidad
        self.qualityMetrics = QualityMetricsService()
        
        // Inicializamos el motor de escucha (Actor) con métricas
        let listener = ContinuousSpeechListener(qualityMetrics: qualityMetrics)
        self.speechListener = listener
        
        // Inicializamos el repositorio (Adaptador)
        self.speechRepository = SpeechRepository(listener: listener)
        
        // /CAMBIO/ Inyectamos el servicio de métricas en el segmentador
        self.nlpSegmenter = NLPSegmenterService(qualityMetrics: qualityMetrics)
        
        // /CAMBIO/ Inyectamos métricas en el Use Case
        self.transcribeUseCase = TranscribeAudioUseCase(
            repository: speechRepository,
            segmenter: nlpSegmenter,
            qualityMetrics: qualityMetrics
        )
    }
    
    /// Factory Method para el ViewModel.
    /// Inyectamos el Use Case que ya tiene todas sus dependencias resueltas.
    @MainActor
    func makeTranscriptionViewModel() -> TranscriptionViewModel {
        return TranscriptionViewModel(transcribeUseCase: transcribeUseCase)
    }
}
