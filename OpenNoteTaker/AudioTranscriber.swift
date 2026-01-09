/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An object that manages Moonshine Voice transcription for captured audio.
*/
import Foundation
import AVFoundation
import MoonshineVoice
import OSLog
import SwiftUI

/// Manages audio transcription using Moonshine Voice.
class AudioTranscriber {
    private let logger = Logger()
    private var transcriber: Transcriber?
    private var systemAudioStream: MoonshineVoice.Stream?
    private var micStream: MoonshineVoice.Stream?
    private var micAudioEngine: AVAudioEngine?
    private var isTranscribing = false
    
    /// Optional transcript document to update with transcript events.
    weak var transcriptDocument: TranscriptDocument?
    
    /// Mapping from Moonshine line IDs to our TranscriptLine UUIDs.
    private var lineIdMapping: [UInt64: UUID] = [:]
    
    /// The time when transcription started, used to calculate relative start times.
    private var transcriptionStartTime: Date?
    
    /// Initialize the transcriber with a model path.
    /// - Parameter modelPath: Path to the directory containing model files (e.g., "tiny-en")
    /// - Throws: Error if transcriber cannot be initialized
    func initialize(modelPath: String) throws {
        guard !isTranscribing else {
            logger.warning("Transcriber already initialized")
            return
        }
        
        logger.info("Initializing Moonshine Voice transcriber with model path: \(modelPath)")
        
        // Initialize transcriber with tiny model architecture (suitable for streaming)
        transcriber = try Transcriber(modelPath: modelPath, modelArch: .base)
        
        // Create a stream for real-time transcription from system audio
        systemAudioStream = try transcriber?.createStream(updateInterval: 0.5)
        
        // Add event listeners to print transcript changes and completions
        systemAudioStream?.addListener { [weak self] event in
            self?.handleTranscriptEvent(event)
        }
        
        // Create a stream for real-time transcription from microphone audio
        micStream = try transcriber?.createStream(updateInterval: 0.5)

        try initMic()

        // Add event listeners to print transcript changes and completions
        micStream?.addListener { [weak self] event in
            self?.handleTranscriptEvent(event)
        }
        
        logger.info("Moonshine Voice transcriber initialized successfully")
    }
    
    /// Start transcription.
    func start() throws {
        guard let systemAudioStream = systemAudioStream else {
            throw NSError(domain: "AudioTranscriber", code: 1, 
                        userInfo: [NSLocalizedDescriptionKey: "Transcriber not initialized"])
        }
        
        guard let micStream = micStream else {
            throw NSError(domain: "AudioTranscriber", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Transcriber not initialized"])
        }
        
        guard !isTranscribing else {
            logger.warning("Transcription already started")
            return
        }
        
        transcriptionStartTime = Date()
        lineIdMapping.removeAll()
        
        try systemAudioStream.start()
        try micStream.start()
        isTranscribing = true
        logger.info("Transcription started")
    }
    
    /// Stop transcription.
    func stop() throws {
        guard let systemAudioStream = systemAudioStream else { return }
        guard let micStream = micStream else { return }

        guard isTranscribing else {
            logger.warning("Transcription not started")
            return
        }
        
        try systemAudioStream.stop()
        try micStream.stop()
        isTranscribing = false
        transcriptionStartTime = nil
        lineIdMapping.removeAll()
        logger.info("Transcription stopped")
    }
    
    /// Add audio data to the transcription stream.
    /// - Parameter buffer: AVAudioPCMBuffer containing audio samples
    func addAudio(_ buffer: AVAudioPCMBuffer) throws {
        guard let systemAudioStream = systemAudioStream, isTranscribing else { return }
        
        // Convert AVAudioPCMBuffer to Float array
        guard let floatChannelData = buffer.floatChannelData else {
            logger.warning("Audio buffer does not contain float channel data")
            return
        }
        
        let channelCount = Int(buffer.format.channelCount)
        let frameLength = Int(buffer.frameLength)
        let sampleRate = Int32(buffer.format.sampleRate)
        
        // Use the first channel (mono) or mix channels if multi-channel
        var audioData: [Float]
        
        if channelCount == 1 {
            // Mono audio - directly copy the channel data
            audioData = Array(UnsafeBufferPointer(start: floatChannelData[0], count: frameLength))
        } else {
            // Multi-channel audio - mix down to mono by averaging channels
            audioData = Array(repeating: 0.0, count: frameLength)
            for channel in 0..<channelCount {
                let channelData = UnsafeBufferPointer(start: floatChannelData[channel], count: frameLength)
                for i in 0..<frameLength {
                    audioData[i] += channelData[i] / Float(channelCount)
                }
            }
        }
        
        // Add audio to the transcription stream
        try systemAudioStream.addAudio(audioData, sampleRate: sampleRate)
    }

    func initMic() throws {
        let permissionStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        
        // Log the current permission status for debugging
        let statusDescription: String
        switch permissionStatus {
        case .notDetermined:
            statusDescription = "notDetermined"
        case .denied:
            statusDescription = "denied"
        case .authorized:
            statusDescription = "authorized"
        case .restricted:
            statusDescription = "restricted"
        @unknown default:
            statusDescription = "unknown"
        }
        logger.info("Current microphone permission status: \(statusDescription)")
        print("[PERMISSION] Current microphone permission status: \(statusDescription)")
        
        if permissionStatus == .denied {
            logger.error("Microphone permission was previously denied. Please reset in System Settings > Privacy & Security > Microphone")
            print("[PERMISSION ERROR] Microphone permission was previously denied.")
            print("[PERMISSION] To reset: System Settings > Privacy & Security > Microphone > Remove this app and try again")
            throw MoonshineError.custom(message: "Microphone permission denied. Please grant permission in System Settings > Privacy & Security > Microphone", code: -1)
        }
        
        if permissionStatus == .restricted {
            logger.error("Microphone permission is restricted (parental controls or MDM)")
            print("[PERMISSION ERROR] Microphone permission is restricted")
            throw MoonshineError.custom(message: "Microphone permission is restricted", code: -1)
        }

        if permissionStatus == .notDetermined {
            // Request permission asynchronously
            var permissionGranted = false
            let semaphore = DispatchSemaphore(value: 0)
            
            logger.info("Requesting microphone permission...")
            print("[PERMISSION] Requesting microphone permission...")

            AVCaptureDevice.requestAccess(for: .audio) { granted in
                print("[PERMISSION] requestAccess callback fired with granted: \(granted)")
                permissionGranted = granted
                semaphore.signal()
            }

            semaphore.wait()
            
            // Re-check the status after the request
            let newStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            logger.info("Permission status after request: \(String(describing: newStatus)), callback granted: \(permissionGranted)")

            if !permissionGranted {
                logger.error("Microphone permission denied by user")
                print("[PERMISSION ERROR] Microphone permission denied by user")
                print("[PERMISSION] To reset: System Settings > Privacy & Security > Microphone > Remove this app and try again")
                throw MoonshineError.custom(message: "Microphone permission denied. Please grant permission in System Settings > Privacy & Security > Microphone", code: -1)
            }
        }

        // Final check - ensure we have authorized status
        let finalStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        if finalStatus != .authorized {
            logger.error("Microphone permission not authorized. Status: \(String(describing: finalStatus))")
            print("[PERMISSION ERROR] Microphone permission not authorized. Final status: \(String(describing: finalStatus))")
            throw MoonshineError.custom(message: "Microphone permission not authorized. Please grant permission in System Settings > Privacy & Security > Microphone", code: -1)
        }
        
        logger.info("Microphone permission authorized")
        print("[PERMISSION] Microphone permission authorized")

        // Set up audio engine
        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        // Create target format
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16000,
                channels: AVAudioChannelCount(1),
                interleaved: false
            )
        else {
            throw MoonshineError.custom(message: "Failed to create target audio format", code: -1)
        }

        // Install tap on input node
        inputNode.installTap(onBus: 0, bufferSize: 512, format: inputFormat) {
            [weak self] (buffer, time) in

            var audioData: [Float] = []
            var finalSampleRate: Double = 16000

            guard let channelData = buffer.floatChannelData else { return }
            let frameLength = Int(buffer.frameLength)
            audioData.reserveCapacity(frameLength)

            audioData.append(
                contentsOf: UnsafeBufferPointer(start: channelData[0], count: frameLength))
            finalSampleRate = inputFormat.sampleRate

            // Feed audio to stream
            do {
                guard let self = self, let micStream = self.micStream else { return }
                try micStream.addAudio(audioData, sampleRate: Int32(finalSampleRate))
            } catch {
                print("MicTranscriber: Error adding audio to stream: \(error.localizedDescription)")
            }
        }

        // Start the audio engine
        try engine.start()

        micAudioEngine = engine
    }
    
    /// Handle transcript events and print to console.
    private func handleTranscriptEvent(_ event: TranscriptEvent) {
        switch event {
        case let lineTextChanged as LineTextChanged:
            // Print when transcript line text changes
            print("[TRANSCRIPT TEXT CHANGED] Line \(lineTextChanged.line.lineId): \"\(lineTextChanged.line.text)\"")
            logger.info("Transcript text changed: Line \(lineTextChanged.line.lineId) - \"\(lineTextChanged.line.text)\"")
            
            // Update the document if available
            updateDocumentForLine(lineTextChanged.line)
            
        case let lineCompleted as LineCompleted:
            // Print when transcript line is completed
            print("[TRANSCRIPT COMPLETED] Line \(lineCompleted.line.lineId): \"\(lineCompleted.line.text)\" (start: \(String(format: "%.2f", lineCompleted.line.startTime))s, duration: \(String(format: "%.2f", lineCompleted.line.duration))s)")
            logger.info("Transcript completed: Line \(lineCompleted.line.lineId) - \"\(lineCompleted.line.text)\"")
            
            // Update the document with the final line
            updateDocumentForLine(lineCompleted.line)
            
        case let lineStarted as LineStarted:
            // Optionally print when a new line starts
            print("[TRANSCRIPT LINE STARTED] Line \(lineStarted.line.lineId): \"\(lineStarted.line.text)\"")
            logger.debug("Transcript line started: Line \(lineStarted.line.lineId)")
            
            // Add the new line to the document
            addLineToDocument(lineStarted.line)
            
        case let lineUpdated as LineUpdated:
            // Optionally print when a line is updated (but text hasn't changed)
            logger.debug("Transcript line updated: Line \(lineUpdated.line.lineId)")
            
            // Update the document
            updateDocumentForLine(lineUpdated.line)
            
        case let error as TranscriptError:
            // Print errors
            print("[TRANSCRIPT ERROR] \(error.error.localizedDescription)")
            logger.error("Transcript error: \(error.error.localizedDescription)")
            
        default:
            break
        }
    }
    
    /// Add a new line to the transcript document, or update if it already exists.
    /// - Parameter line: The Moonshine Line object
    private func addLineToDocument(_ line: MoonshineVoice.TranscriptLine) {
        guard let document = transcriptDocument else { return }
        
        // Check if we already have this line
        if let existingUUID = lineIdMapping[line.lineId] {
            // Line already exists, just update it
            // Extract text before sending to main actor
            let text = line.text
            Task { @MainActor in
                document.updateLine(id: existingUUID, text: text)
            }
            return
        }
        
        // Calculate relative start time from transcription start
        // Convert Float to TimeInterval (Double)
        let relativeStartTime: TimeInterval = TimeInterval(line.startTime)
        
        // Create a new TranscriptLine
        let transcriptLine = TranscriptLine(
            text: line.text,
            startTime: relativeStartTime,
            duration: TimeInterval(line.duration)
        )
        
        // Store the mapping from Moonshine lineId to our UUID
        lineIdMapping[line.lineId] = transcriptLine.id
        
        // Add to document on main actor
        Task { @MainActor in
            document.addLine(transcriptLine)
        }
    }
    
    /// Update an existing line in the transcript document.
    /// - Parameter line: The Moonshine Line object
    private func updateDocumentForLine(_ line: MoonshineVoice.TranscriptLine) {
        guard let document = transcriptDocument else { return }
        
        // If we don't have a mapping yet, create the line first
        if lineIdMapping[line.lineId] == nil {
            addLineToDocument(line)
            return
        }
        
        guard let uuid = lineIdMapping[line.lineId] else { return }
        
        // Extract text before sending to main actor
        let text = line.text
        
        // Update the line text on main actor
        Task { @MainActor in
            document.updateLine(id: uuid, text: text)
        }
    }
    
    /// Clean up resources.
    func cleanup() {
        do {
            try stop()
        } catch {
            logger.error("Error stopping transcription during cleanup: \(error.localizedDescription)")
        }
        
        systemAudioStream?.close()
        transcriber?.close()
        systemAudioStream = nil
        transcriber = nil
        isTranscribing = false
    }
    
    deinit {
        cleanup()
    }
}

