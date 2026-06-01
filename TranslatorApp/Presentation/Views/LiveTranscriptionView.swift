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
<<<<<<< HEAD

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
                        englishPane()
=======
    
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
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
                    }
                    .frame(width: totalWidth * 0.35)
                    .padding(.top)
                    .background(Color(white: 0.12))
<<<<<<< HEAD

                    Divider().background(Color.gray.opacity(0.3))

                    VStack(alignment: .leading, spacing: 8) {
                        headerView(title: "OFFLINE TRANSLATION (ES)", icon: "character.bubble.fill", color: .blue)
                        spanishPane()
=======
                    
                    Divider().background(Color.gray.opacity(0.3))
                    
                    VStack(alignment: .leading, spacing: 8) {
                        headerView(title: "OFFLINE TRANSLATION (ES)", icon: "character.bubble.fill", color: .blue)
                        scrollableTextView(text: viewModel.translatedBuffer, id: "tr_end", color: .cyan)
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
                    }
                    .frame(width: totalWidth * 0.60)
                    .padding(.top)
                    .background(Color(white: 0.08))
<<<<<<< HEAD

=======
                    
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
                    VStack(alignment: .leading, spacing: 8) {}
                        .frame(width: totalWidth * 0.05)
                        .background(Color(white: 0.08))
                }
            }
            .ignoresSafeArea(edges: .bottom)
<<<<<<< HEAD

            VStack(spacing: 12) {

=======
            
            VStack(spacing: 12) {
                
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
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
<<<<<<< HEAD
            guard let requests = viewModel.translationRequests else { return }

            viewLogger.info("🚀 [UI] Translation engine active and listening")

            var translateSeq = 0
            for await sentence in requests {
                guard sentence.trimmingCharacters(in: .whitespaces).count > 2 else { continue }

                let seq = translateSeq
                translateSeq += 1
                let startTime = Date()
                viewLogger.info("[TRANSLATE-START id=\(seq)] '\(sentence)'")

                do {
                    let response = try await session.translate(sentence)
                    let ms = Int(Date().timeIntervalSince(startTime) * 1000)
                    let translated = response.targetText
                        .trimmingCharacters(in: .whitespacesAndNewlines)

                    viewLogger.info("[TRANSLATE-DONE id=\(seq) ms=\(ms)] '\(translated)'")

                    await MainActor.run {
                        viewModel.appendTranslation(translated)
                    }
                } catch {
                    viewLogger.error("❌ [UI] Translation engine error: \(error.localizedDescription)")
=======
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
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
                    if error.localizedDescription.contains("interrupted") {
                        await MainActor.run { viewModel.stopRecording() }
                    }
                }
            }
        }
        .id(taskID)
        .onChange(of: viewModel.isRecording) { _, isRecording in
            if isRecording {
<<<<<<< HEAD
                // Forzar a SwiftUI a destruir el subárbol del .translationTask previo
                // antes de asignar el nuevo config. Sin esta mutación el motor de
                // traducción nunca se recrea entre sesiones.
                taskID = UUID()
=======
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
                translationConfig = .init(source: .init(identifier: "en-US"),
                                          target: .init(identifier: "es-ES"))
            } else {
                translationConfig = nil
            }
        }
        .preferredColorScheme(.dark)
    }
<<<<<<< HEAD

=======
    
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
    private func headerView(title: String, icon: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon).foregroundStyle(color)
            Text(title).font(.system(size: 10, weight: .bold))
        }
        .padding([.horizontal, .top])
        .foregroundStyle(.secondary)
    }
<<<<<<< HEAD

    private func englishPane() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if viewModel.emittedPhrases.isEmpty && viewModel.currentBuffer.isEmpty {
                        Text("Esperando audio...")
                            .font(.system(size: 12, weight: .regular, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        ForEach(Array(viewModel.emittedPhrases.enumerated()), id: \.offset) { _, phrase in
                            Text(phrase)
                                .font(.system(size: 11, weight: .regular, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                        }

                        Text(viewModel.currentBuffer)
                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.green)
                            .animation(.easeInOut(duration: 0.15), value: viewModel.currentBuffer)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal)
                    }

                    Color.clear.frame(height: 1).id("raw_end")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.currentBuffer) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("raw_end", anchor: .bottom)
                }
            }
            .onChange(of: viewModel.emittedPhrases.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("raw_end", anchor: .bottom)
                }
            }
        }
    }

    private func spanishPane() -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if viewModel.translatedSentences.isEmpty {
                        Text("Esperando traducción...")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                    } else {
                        let sentences = viewModel.translatedSentences
                        let lastIndex = sentences.count - 1
                        ForEach(Array(sentences.enumerated()), id: \.offset) { index, sentence in
                            let isLast = index == lastIndex
                            Text(sentence)
                                .font(.system(size: isLast ? 20 : 18,
                                              weight: isLast ? .semibold : .medium))
                                .foregroundStyle(isLast ? Color.white : Color.cyan)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal)
                                .id(isLast ? "tr_end" : "tr_\(index)")
                        }
                    }

                    Color.clear.frame(height: 1).id("tr_bottom")
                }
                .padding(.vertical, 8)
            }
            .onChange(of: viewModel.translatedSentences.count) { _, _ in
                withAnimation(.easeOut(duration: 0.25)) {
                    proxy.scrollTo("tr_bottom", anchor: .bottom)
=======
    
    private func scrollableTextView(text: String, id: String, color: Color = .white , fontSise: CGFloat = 16) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(text.isEmpty ? "Esperando audio..." : text)
                        .font(.system(size: fontSise, weight: .medium, design: .monospaced))
                        .foregroundStyle(color)
                        .animation(.easeInOut(duration: 0.2), value: text)
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
>>>>>>> c854965b69dd24f9bce709588d2924586dc2b0d2
                }
            }
        }
    }
}
