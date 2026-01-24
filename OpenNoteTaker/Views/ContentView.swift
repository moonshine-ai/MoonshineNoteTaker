/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The app's main view.
*/

import AVFoundation
import AppKit
import Combine
import OSLog
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @ObservedObject var document: TranscriptDocument

  @Environment(\.undoManager) private var undoManager

  @State var isUnauthorized = false
  @State private var audioPlayerCancellable: AnyCancellable?
  @State private var playbackReachedEnd = false
  @State private var extractedAudioBuffers: [URL: [Float]] = [:]

  @StateObject var screenRecorder = ScreenRecorder()
  @StateObject var audioPlayer: AudioPlayer = AudioPlayer()

  @AppStorage("fontSize") private var fontSize: Double = 14.0

  @State private var pausedPlayingIds: [UInt64] = []
  @State private var selectedLineIds: [UInt64] = []

  var body: some View {
    ZStack {
      // Main content area - transcript view fills entire space
      TranscriptView(document: document, selectedLineIds: $selectedLineIds, onFileDrag: handleFileDragFromTextView)
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
          .help(
            audioPlayer.isPlaying
              ? "Playback in progress"
              : (screenRecorder.isRunning ? "Stop Recording" : "Start Recording")
          )
          .padding(.bottom, 10)
          Button(action: {
            Task {
              if audioPlayer.isPlaying {
                audioPlayer.stop()
                pausedPlayingIds = document.playingLineIds
                document.playingLineIds = []
              } else {
                document.playingLineIds = pausedPlayingIds
                document.setPlaybackRangeFromLineIds(lineIds: selectedLineIds)
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
          .help(
            audioPlayer.isPlaying
              ? "Pause"
              : (screenRecorder.isRunning
                ? "Recording in progress"
                : (document.hasAudioData() ? "Play" : "No audio recorded"))
          )
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
            Text(
              "Open System Settings and go to Privacy & Security > Screen Recording to grant permission."
            )
            .font(.title2)
            .padding(.bottom)
            .multilineTextAlignment(.center)
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
            document.resetCurrentPlaybackOffset()
            document.playingLineIds = []
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
    .onReceive(NotificationCenter.default.publisher(for: .importFiles)) { _ in
      showImportFilePicker()
    }
    .focusedSceneValue(\.exportAction) {
      showExportFilePicker()
    }
  }

  /// Handle file drags from the text view (NSDraggingInfo)
  private func handleFileDragFromTextView(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    guard
      let urls = pasteboard.readObjects(
        forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    else {
      return false
    }

    // Process the dropped files
    for url in urls {
      Task {
        await extractAudioToPCMBuffer(from: url)
      }
    }

    return true
  }

  /// Handle file drops on the document window
  private func handleFileDrop(providers: [NSItemProvider]) -> Bool {
    var urls: [URL] = []
    let group = DispatchGroup()

    for provider in providers {
      group.enter()
      // Try loading as file URL first
      if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) {
          (data, error) in
          defer { group.leave() }

          if let error = error {
            print("Error loading dropped file: \(error.localizedDescription)")
            return
          }

          if let data = data as? Data,
            let urlString = String(data: data, encoding: .utf8),
            let url = URL(string: urlString)
          {
            urls.append(url)
          } else if let url = data as? URL {
            urls.append(url)
          }
        }
      } else {
        // Fallback: try loading as a general item
        provider.loadItem(forTypeIdentifier: UTType.item.identifier, options: nil) {
          (data, error) in
          defer { group.leave() }

          if let error = error {
            print("Error loading dropped file: \(error.localizedDescription)")
            return
          }

          if let url = data as? URL {
            urls.append(url)
          } else if let data = data as? Data,
            let urlString = String(data: data, encoding: .utf8),
            let url = URL(string: urlString)
          {
            urls.append(url)
          }
        }
      }
    }

    group.notify(queue: .main) {
      // Extract audio from all dropped file URLs
      for url in urls {
        Task {
          await extractAudioToPCMBuffer(from: url)
        }
      }
    }

    return true
  }

  /// Extract audio from a file URL using AVAssetExportSession and store as PCM buffer in memory
  /// - Parameter url: The file URL to extract audio from
  private func extractAudioToPCMBuffer(from url: URL) async {
    // Create AVAsset from URL
    let asset = AVAsset(url: url)

    // Check if asset has audio tracks
    let audioTracks = try? await asset.loadTracks(withMediaType: .audio)
    guard let tracks = audioTracks, !tracks.isEmpty else {
      print("No audio tracks found in file: \(url.lastPathComponent)")
      return
    }

    // Create temporary file URL for exported audio
    let tempDir = FileManager.default.temporaryDirectory
    let tempFileURL = tempDir.appendingPathComponent(UUID().uuidString).appendingPathExtension(
      "m4a")

    // Create export session
    guard
      let exportSession = AVAssetExportSession(
        asset: asset, presetName: AVAssetExportPresetAppleM4A)
    else {
      print("Failed to create export session for: \(url.lastPathComponent)")
      return
    }

    exportSession.outputURL = tempFileURL
    exportSession.outputFileType = .m4a

    // Export audio to temporary file
    await exportSession.export()

    guard exportSession.status == .completed else {
      if let error = exportSession.error {
        print("Export failed for \(url.lastPathComponent): \(error.localizedDescription)")
      }
      // Clean up temp file if it exists
      try? FileManager.default.removeItem(at: tempFileURL)
      return
    }

    // Read the exported file into PCM buffer
    do {
      let audioFile = try AVAudioFile(forReading: tempFileURL)
      let format = audioFile.processingFormat

      // Create target format: mono, float32, 48000 Hz (matching the app's standard format)
      guard
        let targetFormat = AVAudioFormat(
          commonFormat: .pcmFormatFloat32,
          sampleRate: 48000,
          channels: 1,
          interleaved: false
        )
      else {
        print("Failed to create target audio format")
        try? FileManager.default.removeItem(at: tempFileURL)
        return
      }

      // Use AVAudioConverter if format conversion is needed
      let frameLength = AVAudioFrameCount(audioFile.length)
      guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else {
        print("Failed to create audio buffer")
        try? FileManager.default.removeItem(at: tempFileURL)
        return
      }

      try audioFile.read(into: buffer)

      // Convert to target format if needed
      var pcmBuffer = buffer
      if format != targetFormat {
        guard let converter = AVAudioConverter(from: format, to: targetFormat) else {
          print("Failed to create audio converter")
          try? FileManager.default.removeItem(at: tempFileURL)
          return
        }

        let ratio = targetFormat.sampleRate / format.sampleRate
        let outputFrameCount = Int(ceil(Double(buffer.frameLength) * ratio))

        guard
          let convertedBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(outputFrameCount)
          )
        else {
          print("Failed to create converted buffer")
          try? FileManager.default.removeItem(at: tempFileURL)
          return
        }

        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
          outStatus.pointee = .haveData
          return buffer
        }

        converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputBlock)

        if let error = error {
          print("Audio conversion error: \(error.localizedDescription)")
          try? FileManager.default.removeItem(at: tempFileURL)
          return
        }

        pcmBuffer = convertedBuffer
      }

      // Extract PCM data as Float array
      guard let floatChannelData = pcmBuffer.floatChannelData else {
        print("Failed to extract float channel data")
        try? FileManager.default.removeItem(at: tempFileURL)
        return
      }

      let pcmFrameLength = Int(pcmBuffer.frameLength)
      let pcmData = Array(UnsafeBufferPointer(start: floatChannelData[0], count: pcmFrameLength))

      guard let audioTranscriber = await screenRecorder.getAudioTranscriber() else {
        print("Audio transcriber not found")
        return
      }
      await MainActor.run {
        extractedAudioBuffers[url] = pcmData
        audioTranscriber.addImportedAudio(buffer: pcmData, startTime: Date())
      }

      // Clean up temporary file
      try? FileManager.default.removeItem(at: tempFileURL)

    } catch {
      print("Error reading audio file: \(error.localizedDescription)")
      try? FileManager.default.removeItem(at: tempFileURL)
    }
  }

  /// Show file picker for importing audio files
  private func showImportFilePicker() {
    let panel = NSOpenPanel()
    panel.allowsMultipleSelection = true
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    panel.allowedContentTypes = []  // Allow all file types
    
    panel.begin { response in
      if response == .OK {
        // Extract audio from all selected file URLs
        for url in panel.urls {
          Task {
            await extractAudioToPCMBuffer(from: url)
          }
        }
      }
    }
  }

  /// Show file picker for exporting text as RTF
  private func showExportFilePicker() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.rtf]
    panel.nameFieldStringValue = document.title.isEmpty ? "Untitled" : document.title
    panel.canCreateDirectories = true
    
    panel.begin { response in
      if response == .OK, let url = panel.url {
        exportTextAsRTF(to: url)
      }
    }
  }

  /// Export the document's attributed text as RTF to the specified URL
  private func exportTextAsRTF(to url: URL) {
    let attributedText = document.attributedText
    
    // Convert NSAttributedString to RTF data
    let range = NSRange(location: 0, length: attributedText.length)
    guard let rtfData = try? attributedText.data(
      from: range,
      documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
    ) else {
      print("Failed to convert attributed text to RTF")
      return
    }
    
    // Write RTF data to file
    do {
      try rtfData.write(to: url)
    } catch {
      print("Failed to write RTF file: \(error.localizedDescription)")
    }
  }
}
