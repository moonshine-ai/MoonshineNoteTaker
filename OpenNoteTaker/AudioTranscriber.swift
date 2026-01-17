/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An object that manages Moonshine Voice transcription for captured audio.
*/
import Foundation
import AVFoundation
import ScreenCaptureKit
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
    private var debugAudioData: [Float] = []
    private var documentsPath: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!.appendingPathComponent("debug_audio")
    private var lastSystemSegmentStartTime: Float = -1.0
    private var lastSystemSegmentEndTime: Float = -1.0

    /// Optional transcript document to update with transcript events.
    weak var transcriptDocument: TranscriptDocument?
        
    /// The time when transcription started, used to calculate relative start times.
    private var transcriptionStartTime: Date?

    /// Audio data from files dropped on the document window.
    private var importedAudioBuffer: [Float] = []
    private var importedAudioStartTime: Date? = nil
    private var importedAudioStream: MoonshineVoice.Stream? = nil
    private let importedAudioChunkDuration: Double = 5.0
    private let importedAudioSampleRate: Int32 = 48000
    private var importedAudioBufferLock = NSLock()

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
        let options: [TranscriberOption] = []
        if !FileManager.default.fileExists(atPath: self.documentsPath.path) {
            try FileManager.default.createDirectory(at: self.documentsPath, withIntermediateDirectories: true, attributes: nil)
        }
        // Uncomment to save debug audio to disk.
        // options.append(TranscriberOption(name: "save_input_wav_path", value: self.documentsPath.path));
        // print("Saving debug audio to: '\(options[0].name): \(options[0].value)'")
        transcriber = try Transcriber(modelPath: modelPath, modelArch: .base, options: options)
        
        // Create a stream for real-time transcription from system audio
        systemAudioStream = try transcriber?.createStream(updateInterval: 0.5)
        
        // Add event listeners to print transcript changes and completions
        systemAudioStream?.addListener { [weak self] event in
            self?.handleTranscriptEvent(event)
        }
        
        // Create a stream for real-time transcription from microphone audio
        micStream = try transcriber?.createStream(updateInterval: 0.5)

        // Add event listeners to print transcript changes and completions
        micStream?.addListener { [weak self] event in
            self?.handleTranscriptEvent(event)
        }

        importedAudioStream = try transcriber?.createStream(updateInterval: importedAudioChunkDuration)
        importedAudioStream?.addListener { [weak self] event in
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
        transcriptDocument?.startNewRecordingBlock()
        
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
        logger.info("Transcription stopped")

        transcriptDocument?.endCurrentRecordingBlock()
    }
    
    /// Add audio data to the transcription stream.
    /// - Parameter buffer: AVAudioPCMBuffer containing audio samples
    func addAudio(_ buffer: AVAudioPCMBuffer, audioType: SCStreamOutputType) throws {
        guard let systemAudioStream = systemAudioStream, isTranscribing else { return }
        
        let destinationStreamOptional: MoonshineVoice.Stream? = (audioType == SCStreamOutputType.microphone ? micStream : systemAudioStream)
        guard let destinationStream = destinationStreamOptional else {
            logger.warning("Destination stream is nil")
            return
        }
        if !destinationStream.isActive() {
            return
        }

        let inputFormat = buffer.format
        let inputSampleRate = inputFormat.sampleRate
        
        // Create target format: mono, float32, same sample rate
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: inputSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            logger.warning("Failed to create target audio format")
            return
        }

        // Use AVAudioConverter for format conversion (handles channel mixing, sample rate, etc.)
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            logger.warning("Failed to create audio converter from \(inputFormat) to \(targetFormat)")
            return
        }
        
        // Calculate output buffer size (may be different due to sample rate conversion)
        let inputFrameCount = Int(buffer.frameLength)
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputFrameCount = Int(ceil(Double(inputFrameCount) * ratio))
        
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: AVAudioFrameCount(outputFrameCount)
        ) else {
            logger.warning("Failed to create output audio buffer")
            return
        }
        
        // Perform conversion
        var error: NSError?
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        
        converter.convert(to: outputBuffer, error: &error, withInputFrom: inputBlock)
        
        if let error = error {
            logger.error("Audio conversion error: \(error.localizedDescription)")
            throw error
        }
        
        // Extract mono float data from converted buffer
        guard let outputFloatChannelData = outputBuffer.floatChannelData else {
            logger.warning("Converted buffer does not contain float channel data")
            return
        }
        
        let outputFrameLength = Int(outputBuffer.frameLength)
        let monoAudioData = Array(UnsafeBufferPointer(start: outputFloatChannelData[0], count: outputFrameLength))

        try destinationStream.addAudio(monoAudioData, sampleRate: Int32(targetFormat.sampleRate))

        if audioType == SCStreamOutputType.microphone {
            transcriptDocument?.addMicAudio(monoAudioData)
        } else {
            transcriptDocument?.addSystemAudio(monoAudioData)
        }
    }
    
    /// Handle transcript events and print to console.
    private func handleTranscriptEvent(_ event: TranscriptEvent) {
        let beforeSuppressionDuration: Float = 0.5
        let afterSuppressionDuration: Float = 1.0
        let audioType: SCStreamOutputType = (event.streamHandle == 
          systemAudioStream?.getHandle() ? SCStreamOutputType.audio : SCStreamOutputType.microphone)
        if audioType == SCStreamOutputType.audio {
            lastSystemSegmentEndTime = event.line.startTime + event.line.duration + afterSuppressionDuration
        }
        let isMicrophone = audioType == SCStreamOutputType.microphone
        let isSystemAudio = audioType == SCStreamOutputType.audio
        let lineStartTime = event.line.startTime
        let lineEndTime = lineStartTime + event.line.duration
        let isSystemSegmentActive = lineStartTime >= lastSystemSegmentStartTime && lineEndTime <= lastSystemSegmentEndTime
        let line: MoonshineVoice.TranscriptLine = event.line
        // Suppress echo by disabling text updates for the microphone stream while speech is
        // detected on the system audio stream.
        let actualText: String        
        if isMicrophone && isSystemSegmentActive {
            actualText = ""
        } else {
            actualText = line.text
        }
        switch event {
        case let lineStarted as LineStarted:
            addLineToDocument(lineStarted.line, actualText: actualText, audioType: audioType)
            if isSystemAudio {
                lastSystemSegmentStartTime = lineStartTime - beforeSuppressionDuration
            }

        case let lineTextChanged as LineTextChanged:
            updateDocumentForLine(lineTextChanged.line, actualText: actualText)
            
        case let lineCompleted as LineCompleted:
            updateDocumentForLine(lineCompleted.line, actualText: actualText + "\n")
            
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
    private func addLineToDocument(_ line: MoonshineVoice.TranscriptLine, actualText: String, audioType: SCStreamOutputType) {
        guard let document = transcriptDocument else { return }
                
        // Calculate relative start time from transcription start
        // Convert Float to TimeInterval (Double)
        let relativeStartTime: Date = transcriptionStartTime?.addingTimeInterval(TimeInterval(line.startTime)) ?? Date()
        
        let source: TranscriptLine.Source = (audioType == SCStreamOutputType.microphone ? TranscriptLine.Source.microphone : TranscriptLine.Source.systemAudio)

        let transcriptLine = TranscriptLine(
            id: line.lineId,
            text: actualText,
            startTime: relativeStartTime,
            duration: TimeInterval(line.duration),
            source: source
        )
        
        // Add to document on main actor
        Task { @MainActor in
            document.addLine(transcriptLine)
        }
    }
    
    /// Update an existing line in the transcript document.
    /// - Parameter line: The Moonshine Line object
    private func updateDocumentForLine(_ line: MoonshineVoice.TranscriptLine, actualText: String?=nil) {
        guard let document = transcriptDocument else { return }

        let text = actualText ?? line.text
        
        // Skip lines with empty text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        
        let lineId: UInt64 = line.lineId;
        Task { @MainActor in
            document.updateLine(id: lineId, text: text)
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

    func addImportedAudio(buffer: [Float], startTime: Date) {
        let alreadyHasAudioData: Bool
        do {
            importedAudioBufferLock.lock()
            defer { importedAudioBufferLock.unlock() }
            alreadyHasAudioData = importedAudioBuffer.count > 0
            importedAudioBuffer.append(contentsOf: buffer)
        }
        if alreadyHasAudioData {
            return
        }
        Task.detached { [weak self] in
            guard let self = self else { return }
            let sampleRate = 48000
            let chunkSeconds: Float = 5.0
            let chunkSamples = Int(Float(sampleRate) * chunkSeconds)

            try? self.importedAudioStream?.start()
            
            while true {
                let importedAudioChunk: [Float] = importedAudioBufferLock.withLock {
                    var chunk: [Float] = []
                    if self.importedAudioBuffer.count >= chunkSamples {
                        chunk = Array(self.importedAudioBuffer.prefix(chunkSamples))
                        self.importedAudioBuffer.removeFirst(chunkSamples)
                    } else if self.importedAudioBuffer.count > 0 {
                        chunk = self.importedAudioBuffer
                        self.importedAudioBuffer.removeAll()
                    }
                    return chunk
                }
                
                if !importedAudioChunk.isEmpty {
                    try? self.importedAudioStream?.addAudio(importedAudioChunk, sampleRate: importedAudioSampleRate)
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                } else {
                    break
                }
            }
        }
        try? self.importedAudioStream?.stop()
     }
}

/// Writes a single-channel float32 WAV file to disk.
/// - Parameters:
///   - filePath: The full path where the WAV file should be written
///   - samples: Array of Float32 audio samples (single channel)
///   - sampleRate: The sample rate in Hz (e.g., 44100, 48000, 16000)
/// - Throws: Error if file cannot be written
func WriteWavFile(filePath: String, samples: [Float], sampleRate: Int) throws {
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 32
    let bytesPerSample = bitsPerSample / 8
    let numSamples = samples.count
    
    // Calculate sizes
    let dataChunkSize = UInt32(numSamples * Int(numChannels) * Int(bytesPerSample))
    let fmtChunkSize: UInt32 = 16 // Standard PCM fmt chunk size
    let fileSize = 4 + 4 + 4 + 4 + (4 + 4 + fmtChunkSize) + (4 + 4 + dataChunkSize)
    
    // Create data buffer
    var data = Data()
    
    // RIFF header
    data.append("RIFF".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Data($0) })
    data.append("WAVE".data(using: .ascii)!)
    
    // fmt chunk
    data.append("fmt ".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: fmtChunkSize.littleEndian) { Data($0) })
    let audioFormat: UInt16 = 3 // IEEE float
    data.append(contentsOf: withUnsafeBytes(of: audioFormat.littleEndian) { Data($0) })
    data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Data($0) })
    data.append(contentsOf: withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { Data($0) })
    let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bytesPerSample)
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Data($0) })
    let blockAlign = numChannels * bytesPerSample
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Data($0) })
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Data($0) })
    
    // data chunk
    data.append("data".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: dataChunkSize.littleEndian) { Data($0) })
    
    // Audio samples (float32, little-endian)
    for sample in samples {
        data.append(contentsOf: withUnsafeBytes(of: sample.bitPattern.littleEndian) { Data($0) })
    }
    
    // Write to file
    try data.write(to: URL(fileURLWithPath: filePath), options: .atomic)
}

// Extension to get bit pattern of Float for writing
extension Float {
    var bitPattern: UInt32 {
        return withUnsafeBytes(of: self) { $0.load(as: UInt32.self) }
    }
}

