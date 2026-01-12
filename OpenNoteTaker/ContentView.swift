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
    
    @State var userStopped = false
    @State var isUnauthorized = false
    
    @StateObject var screenRecorder = ScreenRecorder()
    
    var body: some View {
        VStack(spacing: 0) {
            // Top section with recording button
            HStack {
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
                    HStack {
                        Image(systemName: screenRecorder.isRunning ? "stop.circle.fill" : "record.circle.fill")
                            .font(.title2)
                        Text(screenRecorder.isRunning ? "Stop Recording" : "Start Recording")
                            .font(.headline)
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(screenRecorder.isRunning ? Color.red : Color.blue)
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding()
            .background(Color.white)
            
            // Main content area - split between capture preview and transcript
            HSplitView {
                // Left side: Capture preview
                screenRecorder.capturePreview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .aspectRatio(screenRecorder.contentSize, contentMode: .fit)
                    .padding(8)
                    .overlay {
                        if userStopped {
                            Image(systemName: "nosign")
                                .font(.system(size: 250, weight: .bold))
                                .foregroundColor(Color(white: 0.3, opacity: 1.0))
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(Color(white: 0.0, opacity: 0.5))
                        }
                    }
                    .overlay {
                        if isUnauthorized {
                            VStack() {
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
                
                // Right side: Transcript view
                TranscriptView(document: screenRecorder.transcriptDocument)
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: CGFloat.infinity)
            }
        }
        .background(Color.white)
        .navigationTitle("Open Note Taker")
        .onAppear {
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
        ContentView()
    }
}
