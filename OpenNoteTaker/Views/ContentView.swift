/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's main view.
*/

import SwiftUI
import ScreenCaptureKit
import OSLog
import Combine
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var document: TranscriptDocument
    
    @Environment(\.undoManager) private var undoManager
    
    @State var isUnauthorized = false
    @State private var audioPlayerCancellable: AnyCancellable?
    @State private var playbackReachedEnd = false
    
    @StateObject var screenRecorder = ScreenRecorder()
    @StateObject var zoomHandler = ZoomHandler.shared
    @StateObject var audioPlayer: AudioPlayer = AudioPlayer()
    
    var body: some View {
        ZStack {
            // Main content area - transcript view fills entire space
            TranscriptView(document: document)
                .environmentObject(zoomHandler)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            
            // Floating recording button overlay at bottom center
            VStack {
                Spacer()
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
                        Image(systemName: screenRecorder.isRunning ? "pause.circle.fill" : "record.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(screenRecorder.isRunning ? Color.red : Color.blue)
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(audioPlayer.isPlaying)
                    .opacity(audioPlayer.isPlaying ? 0.5 : 1.0)
                    .onHover { hovering in
                        if hovering {
                            if audioPlayer.isPlaying {
                                NSCursor.operationNotAllowed.push()
                            } else {
                                NSCursor.pointingHand.push()
                            }
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .help(audioPlayer.isPlaying ? "Playback in progress" : (screenRecorder.isRunning ? "Stop Recording" : "Start Recording"))
                    .padding(.bottom, 10)
                    Button(action: {
                        Task {
                            if audioPlayer.isPlaying {
                                audioPlayer.stop()
                                document.blockPlaybackRangeUpdates = false
                            } else {                                
                                document.blockPlaybackRangeUpdates = true
                                try audioPlayer.play()
                            }
                        }
                    }) {
                        Image(systemName: audioPlayer.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.title2)
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.blue)
                            .cornerRadius(8)
                            .shadow(color: .black.opacity(0.3), radius: 8, x: 0, y: 4)
                    }
                    .buttonStyle(.plain)
                    .disabled(!document.hasAudioData() || screenRecorder.isRunning)
                    .opacity((document.hasAudioData() && !screenRecorder.isRunning) ? 1.0 : 0.5)
                    .onHover { hovering in
                        if hovering {
                            if document.hasAudioData() && !screenRecorder.isRunning {
                                NSCursor.pointingHand.push()
                            } else {
                                NSCursor.operationNotAllowed.push()
                            }
                        } else {
                            NSCursor.pop()
                        }
                    }
                    .help(audioPlayer.isPlaying ? "Pause" : (screenRecorder.isRunning ? "Recording in progress" : (document.hasAudioData() ? "Play" : "No audio recorded")))
                    .padding(.bottom, 10)
                }
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
        .onDrop(of: [UTType.item], isTargeted: nil) { providers in
            handleFileDrop(providers: providers)
        }
        .onAppear {
            // Connect the undo manager from DocumentGroup to the document
            document.undoManager = undoManager
            
            // Connect the document from DocumentGroup to ScreenRecorder
            screenRecorder.transcriptDocument = document
            Task {
                let canRecord = await screenRecorder.canRecord
                if !canRecord {
                    isUnauthorized = true
                }
            }
            audioPlayer.transcriptDocument = document
            
            document.setPlaybackRange(startOffset: 0, endOffset: -1)

            // Subscribe to audio player events
            // These events are posted from the audio thread and handled on the main thread
            audioPlayerCancellable = audioPlayer.events
                .receive(on: DispatchQueue.main)
                .sink { event in
                    switch event {
                    case .playbackReachedEnd:
                        // Automatically stop playback when it reaches the end
                        audioPlayer.stop()
                        document.blockPlaybackRangeUpdates = false
                        document.resetCurrentPlaybackOffset()
                    case .playbackLineIdsUpdated(_, let newLineIds):
                        document.playingLineIds = newLineIds
                    case .playbackError(let error):
                        // Handle playback errors
                        print("Playback error: \(error.localizedDescription)")
                    }
                }
        }
        .onChange(of: undoManager) { oldValue, newValue in
            // Update the document's undo manager if it changes
            document.undoManager = newValue
        }
    }
    
    /// Handle file drops on the document window
    private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
        var urls: [URL] = []
        let group = DispatchGroup()
        
        for provider in providers {
            group.enter()
            // Try loading as file URL first
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, error) in
                    defer { group.leave() }
                    
                    if let error = error {
                        print("Error loading dropped file: \(error.localizedDescription)")
                        return
                    }
                    
                    if let data = data as? Data,
                       let urlString = String(data: data, encoding: .utf8),
                       let url = URL(string: urlString) {
                        urls.append(url)
                    } else if let url = data as? URL {
                        urls.append(url)
                    }
                }
            } else {
                // Fallback: try loading as a general item
                provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) { (data, error) in
                    defer { group.leave() }
                    
                    if let error = error {
                        print("Error loading dropped file: \(error.localizedDescription)")
                        return
                    }
                    
                    if let url = data as? URL {
                        urls.append(url)
                    } else if let data = data as? Data,
                              let urlString = String(data: data, encoding: .utf8),
                              let url = URL(string: urlString) {
                        urls.append(url)
                    }
                }
            }
        }
        
        group.notify(queue: .main) {
            // Print all URLs
            for url in urls {
                print("Dropped file URL: \(url.absoluteString)")
            }
        }
        
        return true
    }
}
