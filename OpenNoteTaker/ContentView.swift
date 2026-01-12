/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's main view.
*/

import SwiftUI
import ScreenCaptureKit
import OSLog
import Combine

struct ContentView: View {
    @ObservedObject var document: TranscriptDocument
    
    @State var isUnauthorized = false
    
    @StateObject var screenRecorder = ScreenRecorder()
    
    var body: some View {
        ZStack {
            // Main content area - transcript view fills entire space
            TranscriptView(document: document)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Floating recording button overlay at bottom center
            VStack {
                Spacer()
                Button(action: {
                    Task {
                        if screenRecorder.isRunning {
                            await screenRecorder.stop()
                        } else {
                            // Enable both audio sources before starting
                            screenRecorder.isAudioCaptureEnabled = true
                            screenRecorder.isMicCaptureEnabled = true
                            await screenRecorder.start()
                        }
                    }
                }) {
                    Image(systemName: screenRecorder.isRunning ? "pause.circle.fill" : "record.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white)
                        .padding(10)
                        .background(screenRecorder.isRunning ? Color.red : Color.blue)
                        .cornerRadius(8)
                        .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
            }
            
            // Unauthorized overlay
            if isUnauthorized {
                VStack {
                    Spacer()
                    VStack {
                        Text("No screen recording permission.")
                            .font(.largeTitle)
                            .padding(.top)
                        Text("Open System Settings and go to Privacy & Security > Screen Recording to grant permission.")
                            .font(.title2)
                            .padding(.bottom)
                    }
                    .frame(maxWidth: .infinity)
                    .background(.red)
                }
            }
        }
        .background(Color.white)
        .onAppear {
            // Connect the document from DocumentGroup to ScreenRecorder
            screenRecorder.transcriptDocument = document
            Task {
                let canRecord = await screenRecorder.canRecord
                if !canRecord {
                    isUnauthorized = true
                }
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView(document: TranscriptDocument())
    }
}
