//
//  RecordButton.swift
//  TranslatorApp
//
//  Created by PANESSO Alfredo Sebastian on 11/02/26.
//

import SwiftUI

struct RecordButton: View {
    let isRecording: Bool
    let action: () -> Void
    
    @State private var isPulsing = false
    
    var body: some View {
        Button(action: action) {
            ZStack {
                if isRecording {
                    Circle()
                        .stroke(Color.red.opacity(0.3), lineWidth: 4)
                        .frame(width: 60, height: 60)
                        .scaleEffect(isPulsing ? 1.2 : 1.0)
                        .opacity(isPulsing ? 0.0 : 1.0)
                        .animation(
                            .easeInOut(duration: 1.5)
                            .repeatForever(autoreverses: false),
                            value: isPulsing
                        )
                }
                
                Circle()
                    .fill(isRecording ? .red : .blue)
                    .frame(width: 52, height: 52)
                    .overlay {
                        VStack(spacing: 4) {
                            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(
                        color: (isRecording ? Color.red : Color.blue).opacity(0.4),
                        radius: 8,
                        y: 4
                    )
                    .scaleEffect(isPulsing && !isRecording ? 0.95 : 1.0)
            }
        }
        .buttonStyle(RecordButtonStyle())
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                isPulsing = true
            } else {
                isPulsing = false
            }
        }
        .onAppear {
            if isRecording {
                isPulsing = true
            }
        }
    }
}

struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: configuration.isPressed)
    }
}

#Preview("Recording") {
    RecordButton(isRecording: true) {
        print("Stop recording")
    }
    .padding()
}

#Preview("Not Recording") {
    RecordButton(isRecording: false) {
        print("Start recording")
    }
    .padding()
}
