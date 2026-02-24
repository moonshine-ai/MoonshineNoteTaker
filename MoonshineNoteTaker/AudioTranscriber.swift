import AVFoundation
/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
An object that manages Moonshine Voice transcription for captured audio.
*/
import Foundation
import MoonshineVoice
import OSLog
import ScreenCaptureKit
import SwiftUI

struct QueueEntry {
  let buffer: AVAudioPCMBuffer
  let audioType: SCStreamOutputType

  init(buffer: AVAudioPCMBuffer, audioType: SCStreamOutputType) {
    self.buffer = buffer
    self.audioType = audioType
  }
}

/// Manages audio transcription using Moonshine Voice.
class AudioTranscriber {
  private let logger = Logger()
  private var transcriber: Transcriber?
  private var systemAudioStream: MoonshineVoice.Stream?
  private var micStream: MoonshineVoice.Stream?
  private var micAudioEngine: AVAudioEngine?
  private var isTranscribing = false
  private var debugAudioData: [Float] = []
  private var documentsPath: URL = FileManager.default.urls(
    for: .documentDirectory, in: .userDomainMask
  ).first!.appendingPathComponent("debug_audio")
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

  private var audioQueue: [QueueEntry] = []
  private let audioQueueLock = NSLock()
  private var audioQueueProcessingTask: Task<Void, Never>? = nil
  private var stopRequested = false
  private let transcriptionInterval: Double = 0.5

  private var microphonePCMSampleVendor: MicrophonePCMSampleVendor? = nil

  private var micInputFormat: AVAudioFormat? = nil
  private var micAudioConverter: AVAudioConverter? = nil
 
  private var systemInputFormat: AVAudioFormat? = nil
  private var systemAudioConverter: AVAudioConverter? = nil

  /// Initialize the transcriber with a model path.
  /// - Parameter modelPath: Path to the directory containing model files (e.g., "tiny-en")
  /// - Throws: Error if transcriber cannot be initialized
  func initialize(modelPath: String) throws {
    guard !isTranscribing else {
      logger.warning("Transcriber already initialized")
      return
    }

    logger.info("Initializing Moonshine Voice transcriber with model path: \(modelPath)")

    if !FileManager.default.fileExists(atPath: self.documentsPath.path) {
      try FileManager.default.createDirectory(
        at: self.documentsPath, withIntermediateDirectories: true, attributes: nil)
    }
    let options: [TranscriberOption] = [
      // Uncomment to get more detailed logs and save debug audio to disk.
      // TranscriberOption(name: "save_input_wav_path", value: self.documentsPath.path),
      // TranscriberOption(name: "log_api_calls", value: "true"),
      // TranscriberOption(name: "log_output_text", value: "true"),
    ]
    transcriber = try Transcriber(modelPath: modelPath, modelArch: .mediumStreaming, options: options)

    // Create a stream for real-time transcription from system audio
    systemAudioStream = try transcriber?.createStream(updateInterval: transcriptionInterval)

    // Add event listeners to print transcript changes and completions
    systemAudioStream?.addListener { [weak self] event in
      self?.handleTranscriptEvent(event)
    }

    // Create a stream for real-time transcription from microphone audio
    micStream = try transcriber?.createStream(updateInterval: transcriptionInterval)

    // Add event listeners to print transcript changes and completions
    micStream?.addListener { [weak self] event in
      self?.handleTranscriptEvent(event)
    }

    importedAudioStream = try transcriber?.createStream(updateInterval: importedAudioChunkDuration)
    importedAudioStream?.addListener { [weak self] event in
      self?.handleTranscriptEvent(event)
    }

    self.audioQueueProcessingTask = Task.detached { [weak self] in
      guard let self = self else { return }
      try? await self.processAudioQueue()
    }

    logger.info("Moonshine Voice transcriber initialized successfully")
  }

  /// Start transcription.
  func start() throws {
    guard let systemAudioStream = systemAudioStream else {
      throw NSError(
        domain: "AudioTranscriber", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Transcriber not initialized"])
    }

    guard let micStream = micStream else {
      throw NSError(
        domain: "AudioTranscriber", code: 1,
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

    self.stopRequested = false

    self.microphonePCMSampleVendor = MicrophonePCMSampleVendor()
    let microphonePCMStream = try self.microphonePCMSampleVendor!.start(
      deviceID: AudioDeviceManager.shared.selectedDeviceID
    )
    Task { [weak self] in
      for await sample in microphonePCMStream {
        guard let self = self else { return }
        try? self.addAudio(sample, audioType: SCStreamOutputType.microphone)
      }
    }
    isTranscribing = true
    logger.info("Transcription started")
  }

  /// Stop transcription.
  func stop() throws {
    guard let _ = systemAudioStream else { return }
    guard let _ = micStream else { return }

    guard isTranscribing else {
      logger.warning("Transcription not started")
      return
    }

    Task.detached { [weak self] in
      guard let self = self else { return }
      try? await self.stopWorker()
    }
  }

  private func stopWorker() async throws {
    self.stopRequested = true

    while true {
      let isEmpty: Bool = self.audioQueueLock.withLock {
        self.audioQueue.isEmpty
      }
      if isEmpty {
        break
      }
      try? await Task.sleep(for: .milliseconds(10))
    }

    try systemAudioStream?.stop()
    try micStream?.stop()
    self.microphonePCMSampleVendor?.stop()
    self.microphonePCMSampleVendor = nil

    isTranscribing = false
    transcriptionStartTime = nil
    logger.info("Transcription stopped")

    transcriptDocument?.endCurrentRecordingBlock()
  }

  /// Add audio data to the transcription stream.
  /// - Parameter buffer: AVAudioPCMBuffer containing audio samples
  /// Since this can be called from a time-sensitive thread, we add the buffer 
  /// to a queue and process it in a background thread to avoid any dropped audio
  /// frames.
  func addAudio(_ buffer: AVAudioPCMBuffer, audioType: SCStreamOutputType) throws {
    guard !stopRequested else { return }
    let bufferCopy = buffer.copy() as! AVAudioPCMBuffer
    audioQueueLock.withLock {
      audioQueue.append(QueueEntry(buffer: bufferCopy, audioType: audioType))
    }
  }

  /// Returns a new buffer containing the concatenation of `first` and `second`.
  private func append(_ second: AVAudioPCMBuffer, to first: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
    let totalFrames = first.frameLength + second.frameLength
    guard let result = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: totalFrames) else {
      return nil
    }
    result.frameLength = totalFrames
    let frameLength1 = Int(first.frameLength)
    let frameLength2 = Int(second.frameLength)
    let channelCount = Int(first.format.channelCount)

    if first.format.commonFormat == .pcmFormatInt16 {
      guard let dst = result.int16ChannelData,
            let src1 = first.int16ChannelData,
            let src2 = second.int16ChannelData else {
        return nil
      }
      for channel in 0..<channelCount {
        let s1 = src1[channel]
        let s2 = src2[channel]
        let d = dst[channel]
        memcpy(d, s1, frameLength1 * MemoryLayout<Int16>.size)
        memcpy(d + frameLength1, s2, frameLength2 * MemoryLayout<Int16>.size)
      }
    } else if first.format.commonFormat == .pcmFormatFloat32 {
      guard let dst = result.floatChannelData,
            let src1 = first.floatChannelData,
            let src2 = second.floatChannelData else {
        return nil
      }
      for channel in 0..<channelCount {
        let s1 = src1[channel]
        let s2 = src2[channel]
        let d = dst[channel]
        memcpy(d, s1, frameLength1 * MemoryLayout<Float>.size)
        memcpy(d + frameLength1, s2, frameLength2 * MemoryLayout<Float>.size)
      }
    } else {
      logger.warning("Unsupported audio format")
    }
    return result
  }

  private func processAudioQueue() async throws {
    while true {
      let entries: [QueueEntry] = audioQueueLock.withLock {
        guard !audioQueue.isEmpty else { return [] }
        let result = audioQueue
        audioQueue.removeAll()
        return result
      }
      if entries.isEmpty {
        try? await Task.sleep(for: .milliseconds(10))
        continue
      }
      var systemAudioBuffer: AVAudioPCMBuffer? = nil
      var micAudioBuffer: AVAudioPCMBuffer? = nil
      for entry in entries {
        if entry.audioType == SCStreamOutputType.audio {
          if let existing = systemAudioBuffer {
            systemAudioBuffer = append(entry.buffer, to: existing) ?? existing
          } else {
            systemAudioBuffer = entry.buffer
          }
        } else {
          if let existing = micAudioBuffer {
            micAudioBuffer = append(entry.buffer, to: existing) ?? existing
          } else {
            micAudioBuffer = entry.buffer
          }
        }
      }
      if systemAudioBuffer != nil {
        try processAudioQueueEntry(QueueEntry(buffer: systemAudioBuffer!, audioType: SCStreamOutputType.audio))
      }
      if micAudioBuffer != nil {
        try processAudioQueueEntry(QueueEntry(buffer: micAudioBuffer!, audioType: SCStreamOutputType.microphone))
      }
    }
  }

  private func processAudioQueueEntry(_ entry: QueueEntry) throws {
    let buffer = entry.buffer
    let audioType = entry.audioType
    guard let systemAudioStream = systemAudioStream, isTranscribing else { return }
    let destinationStreamOptional: MoonshineVoice.Stream? =
      (audioType == SCStreamOutputType.microphone ? micStream : systemAudioStream)
    guard let destinationStream = destinationStreamOptional else {
      logger.warning("Destination stream is nil")
      return
    }
    if !destinationStream.isActive() {
      return
    }

    let currentInputFormat = buffer.format

    let needToCreateConverter: Bool
    if audioType == SCStreamOutputType.microphone {
      if self.micInputFormat == nil || self.micInputFormat != currentInputFormat {
        needToCreateConverter = true
        self.micInputFormat = currentInputFormat
      } else {
          needToCreateConverter = false
      }
    } else {
      if self.systemInputFormat == nil || self.systemInputFormat != currentInputFormat {
        needToCreateConverter = true
        self.systemInputFormat = currentInputFormat
      } else {
          needToCreateConverter = false
      }
    }
    
    let targetSampleRate = 48000.0
    guard
      let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: targetSampleRate,
        channels: 1,
        interleaved: false
      )
    else {
      logger.warning("Failed to create target audio format")
      return
    }
    if needToCreateConverter {
      guard let converter: AVAudioConverter = AVAudioConverter(from: currentInputFormat, to: targetFormat) else {
        logger.warning("Failed to create audio converter from \(currentInputFormat) to \(targetFormat)")
        return
      }
      if audioType == SCStreamOutputType.microphone {
        self.micAudioConverter = converter
      } else {
        self.systemAudioConverter = converter
      }
    }

    let converter = audioType == SCStreamOutputType.microphone ? self.micAudioConverter : self.systemAudioConverter
    guard let converter = converter else {
      logger.warning("Audio converter is nil")
      return
    }

    // Calculate output buffer size (may be different due to sample rate conversion)
    let inputFrameCount = Int(buffer.frameLength)
    let ratio = targetSampleRate / currentInputFormat.sampleRate
    let outputFrameCount = Int(ceil(Double(inputFrameCount) * ratio))

    guard
      let outputBuffer = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: AVAudioFrameCount(outputFrameCount)
      )
    else {
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
    let monoAudioData = Array(
      UnsafeBufferPointer(start: outputFloatChannelData[0], count: outputFrameLength))

    try destinationStream.addAudio(monoAudioData, sampleRate: Int32(targetSampleRate))

    if audioType == SCStreamOutputType.microphone {
      transcriptDocument?.addMicAudio(monoAudioData)
    } else {
      transcriptDocument?.addSystemAudio(monoAudioData)
    }
  }

  /// Handle transcript events and print to console.
  private func handleTranscriptEvent(_ event: TranscriptEvent) {
    let audioType: SCStreamOutputType =
      (event.streamHandle == systemAudioStream?.getHandle()
        ? SCStreamOutputType.audio : SCStreamOutputType.microphone)
    let line: MoonshineVoice.TranscriptLine = event.line
    switch event {
    case is LineStarted:
      addLineToDocument(line, actualText: line.text, audioType: audioType)

    case is LineTextChanged:
      updateDocumentForLine(line, actualText: line.text)

    case is LineCompleted:
      updateDocumentForLine(line, actualText: line.text + "\n")

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
  private func addLineToDocument(
    _ line: MoonshineVoice.TranscriptLine, actualText: String, audioType: SCStreamOutputType
  ) {
    guard let document = transcriptDocument else { return }

    // Calculate relative start time from transcription start
    // Convert Float to TimeInterval (Double)
    let relativeStartTime: Date =
      transcriptionStartTime?.addingTimeInterval(TimeInterval(line.startTime)) ?? Date()

    let source: TranscriptLine.Source =
      (audioType == SCStreamOutputType.microphone
        ? TranscriptLine.Source.microphone : TranscriptLine.Source.systemAudio)

    let transcriptLine = TranscriptLine(
      id: line.lineId,
      text: actualText,
      startTime: relativeStartTime,
      duration: TimeInterval(line.duration),
      source: source, hasSpeakerId: line.hasSpeakerId, speakerIndex: line.speakerIndex
    )

    // Add to document on main actor
    Task { @MainActor in
      document.addLine(transcriptLine)
    }
  }

  /// Update an existing line in the transcript document.
  /// - Parameter line: The Moonshine Line object
  private func updateDocumentForLine(
    _ line: MoonshineVoice.TranscriptLine, actualText: String? = nil
  ) {
    guard let document = transcriptDocument else { return }

    let text = actualText ?? line.text
    let duration = TimeInterval(line.duration)

    // Skip lines with empty text
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return
    }

    let lineId: UInt64 = line.lineId
    Task { @MainActor in
      document.updateLine(id: lineId, text: text, duration: duration, hasSpeakerId: line.hasSpeakerId, speakerIndex: line.speakerIndex)
    }
  }

  /// Clean up resources.
  func cleanup() {
    do {
      try stop()
    } catch {
      logger.error("Error stopping transcription during cleanup: \(error.localizedDescription)")
    }

    self.audioQueueProcessingTask?.cancel()
    self.audioQueueProcessingTask = nil

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
      self.transcriptDocument?.startNewRecordingBlock()
      self.transcriptionStartTime = Date()

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
          try? self.importedAudioStream?.addAudio(
            importedAudioChunk, sampleRate: importedAudioSampleRate)
          self.transcriptDocument?.addSystemAudio(importedAudioChunk)
          self.transcriptDocument?.addMicAudio(
            Array(repeating: 0.0, count: importedAudioChunk.count))
          try? await Task.sleep(nanoseconds: 250_000_000)
        } else {
          break
        }
      }
      try? self.importedAudioStream?.stop()
      self.transcriptDocument?.endCurrentRecordingBlock()
    }
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
  let fmtChunkSize: UInt32 = 16  // Standard PCM fmt chunk size
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
  let audioFormat: UInt16 = 3  // IEEE float
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
