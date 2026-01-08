/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An object that manages Moonshine Voice transcription for captured audio.
*/
import Foundation
import AVFoundation
import MoonshineVoice
import OSLog

/// Manages audio transcription using Moonshine Voice.
class AudioTranscriber {
    private let logger = Logger()
    private var transcriber: Transcriber?
    private var stream: MoonshineVoice.Stream?
    private var isTranscribing = false
    
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
        
        // Create a stream for real-time transcription
        stream = try transcriber?.createStream(updateInterval: 0.5)
        
        // Add event listeners to print transcript changes and completions
        try stream?.addListener { [weak self] event in
            self?.handleTranscriptEvent(event)
        }
        
        logger.info("Moonshine Voice transcriber initialized successfully")
    }
    
    /// Start transcription.
    func start() throws {
        guard let stream = stream else {
            throw NSError(domain: "AudioTranscriber", code: 1, 
                        userInfo: [NSLocalizedDescriptionKey: "Transcriber not initialized"])
        }
        
        guard !isTranscribing else {
            logger.warning("Transcription already started")
            return
        }
        
        try stream.start()
        isTranscribing = true
        logger.info("Transcription started")
    }
    
    /// Stop transcription.
    func stop() throws {
        guard let stream = stream else { return }
        
        guard isTranscribing else {
            logger.warning("Transcription not started")
            return
        }
        
        try stream.stop()
        isTranscribing = false
        logger.info("Transcription stopped")
    }
    
    /// Add audio data to the transcription stream.
    /// - Parameter buffer: AVAudioPCMBuffer containing audio samples
    func addAudio(_ buffer: AVAudioPCMBuffer) throws {
        guard let stream = stream, isTranscribing else { return }
        
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
        try stream.addAudio(audioData, sampleRate: sampleRate)
    }
    
    /// Handle transcript events and print to console.
    private func handleTranscriptEvent(_ event: TranscriptEvent) {
        switch event {
        case let lineTextChanged as LineTextChanged:
            // Print when transcript line text changes
            print("[TRANSCRIPT TEXT CHANGED] Line \(lineTextChanged.line.lineId): \"\(lineTextChanged.line.text)\"")
            logger.info("Transcript text changed: Line \(lineTextChanged.line.lineId) - \"\(lineTextChanged.line.text)\"")
            
        case let lineCompleted as LineCompleted:
            // Print when transcript line is completed
            print("[TRANSCRIPT COMPLETED] Line \(lineCompleted.line.lineId): \"\(lineCompleted.line.text)\" (start: \(String(format: "%.2f", lineCompleted.line.startTime))s, duration: \(String(format: "%.2f", lineCompleted.line.duration))s)")
            logger.info("Transcript completed: Line \(lineCompleted.line.lineId) - \"\(lineCompleted.line.text)\"")
            
        case let lineStarted as LineStarted:
            // Optionally print when a new line starts
            print("[TRANSCRIPT LINE STARTED] Line \(lineStarted.line.lineId): \"\(lineStarted.line.text)\"")
            logger.debug("Transcript line started: Line \(lineStarted.line.lineId)")
            
        case let lineUpdated as LineUpdated:
            // Optionally print when a line is updated (but text hasn't changed)
            logger.debug("Transcript line updated: Line \(lineUpdated.line.lineId)")
            
        case let error as TranscriptError:
            // Print errors
            print("[TRANSCRIPT ERROR] \(error.error.localizedDescription)")
            logger.error("Transcript error: \(error.error.localizedDescription)")
            
        default:
            break
        }
    }
    
    /// Clean up resources.
    func cleanup() {
        do {
            try stop()
        } catch {
            logger.error("Error stopping transcription during cleanup: \(error.localizedDescription)")
        }
        
        stream?.close()
        transcriber?.close()
        stream = nil
        transcriber = nil
        isTranscribing = false
    }
    
    deinit {
        cleanup()
    }
}

