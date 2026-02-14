//
//  LiveTranscriptionView.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import SwiftUI
import Translation
import OSLog

struct LiveTranscriptionView: View {
    var viewModel: TranscriptionViewModel
    @State private var translationConfig: TranslationSession.Configuration?
    
    private let viewLogger = Logger(subsystem: "com.spanesso.TraslatorApp", category: "UI")
    
    init(viewModel: TranscriptionViewModel) {
        self.viewModel = viewModel
    }
    
    @State private var taskID = UUID()
    
    var body: some View {
        @Bindable var bindable = viewModel
        
        ZStack(alignment: .topTrailing) {
            GeometryReader { geometry in
                let totalWidth = geometry.size.width
                
                HStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        headerView(title: "ORIGINAL (EN)", icon: "microphone.fill", color: .yellow)
                        scrollableTextView(text: viewModel.currentBuffer, id: "raw_end", color: .green, fontSise: 12)
                    }
                    .frame(width: totalWidth * 0.35)
                    .padding(.top)
                    .background(Color(white: 0.12))
                    
                    Divider().background(Color.gray.opacity(0.3))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        headerView(title: "OFFLINE TRANSLATION (ES)", icon: "character.bubble.fill", color: .blue)
                        scrollableTextView(text: viewModel.translatedBuffer, id: "tr_end", color: .cyan)
                    }
                    .frame(width: totalWidth * 0.60)
                    .padding(.top)
                    .background(Color(white: 0.08))
                    
                    VStack(alignment: .leading, spacing: 8) {}
                        .frame(width: totalWidth * 0.05)
                        .background(Color(white: 0.08))
                }
            }
            .ignoresSafeArea(edges: .bottom)
            
            VStack(spacing: 12) {
                
                RecordButton(isRecording: viewModel.isRecording) {
                    viewModel.toggleRecording()
                }
            }
            .padding(.top, 15)
            .padding(.trailing, 5)
        }
        .alert("Audio Engine Error", isPresented: $bindable.hasError) {
            Button("Ok", role: .cancel) { }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .translationTask(translationConfig) { session in
            // Esperamos a que el ViewModel tenga el stream listo
            guard let requests = viewModel.translationRequests else { return }
            
            viewLogger.info("🚀 [UI] Translation engine active and listening")
            
            for await text in requests {
                do {
                    // Filtro de seguridad para no saturar con micro-frases
                    guard text.trimmingCharacters(in: .whitespaces).count > 2 else { continue }
                    
                    let response = try await session.translate(text)
                    
                    await MainActor.run {
                        viewModel.appendTranslation(response.targetText)
                        viewLogger.info("✅ [UI] Translation displayed")
                    }
                } catch {
                    viewLogger.error("❌ [UI] Translation engine error: \(error.localizedDescription)")
                    // Si hay un error de comunicación, forzamos un reset del config para reiniciar el motor
                    if error.localizedDescription.contains("interrupted") {
                        await MainActor.run { viewModel.stopRecording() }
                    }
                }
            }
        }
        .id(taskID)
        .onChange(of: viewModel.isRecording) { _, isRecording in
            if isRecording {
                translationConfig = .init(source: .init(identifier: "en-US"),
                                          target: .init(identifier: "es-ES"))
            } else {
                translationConfig = nil
            }
        }
        .preferredColorScheme(.dark)
    }
    
    private func headerView(title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.system(size: 10, weight: .bold))
        }
        .padding([.horizontal, .top])
        .foregroundStyle(.secondary)
    }
    
    private func scrollableTextView(text: String, id: String, color: Color = .white , fontSise: CGFloat = 16) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text.isEmpty ? "Esperando audio..." : text)
                        .font(.system(size: fontSise, weight: .medium, design: .monospaced))
                        .foregroundStyle(color)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                    
                    //  Elemento invisible que sirve de ancla para el scroll
                    Color.clear
                        .frame(height: 1)
                        .id(id)
                }
            }
            .onChange(of: text) { _, _ in
                //  Forzamos el scroll al ancla invisible cada vez que el texto cambia
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}
