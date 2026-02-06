/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A document model that holds transcript lines in time order for display and persistence.
*/

import Accelerate
import Foundation
import ScreenCaptureKit
import SwiftUI
import UniformTypeIdentifiers
import SwiftUI

/// Represents a single transcript line with timing information.
struct TranscriptLine: Identifiable, Codable, Equatable {
  /// Unique identifier for the line.
  let id: UInt64

  /// The transcribed text content.
  var text: String

  /// Start time of the line in wall clock time.
  let startTime: Date

  /// Duration of the line in seconds.
  var duration: TimeInterval

  /// Whether the speaker has been identified.
  var hasSpeakerId: Bool

  /// The speaker index for the line.
  var speakerIndex: UInt32

  /// End time of the line (startTime + duration).
  var endTime: Date {
    startTime.addingTimeInterval(duration)
  }

  enum Source: String, Codable, Equatable {
    case microphone
    case systemAudio
  }

  let source: Source

  init(
    id: UInt64, text: String, startTime: Date, duration: TimeInterval,
    source: TranscriptLine.Source, hasSpeakerId: Bool, speakerIndex: UInt32
  ) {
    self.id = id
    self.text = text
    self.startTime = startTime
    self.duration = duration
    self.source = source
    self.hasSpeakerId = hasSpeakerId
    self.speakerIndex = speakerIndex
  }
}

struct RecordingBlock: Equatable {
  let startTime: Date
  var endTime: Date
  var micAudio: [Float]  // In-memory only, not Codable
  var systemAudio: [Float]  // In-memory only, not Codable
  var audioCount: Int {
    max(micAudio.count, systemAudio.count)
  }

  // File references for bundle format (used during save/load)
  var micAudioFile: String?
  var systemAudioFile: String?

  // Codable version for JSON (excludes audio arrays)
  struct CodableBlock: Codable {
    let startTime: Date
    let endTime: Date
    let micAudioFile: String
    let systemAudioFile: String
  }

  var codable: CodableBlock? {
    guard let micFile = micAudioFile, let systemFile = systemAudioFile else {
      return nil
    }
    return CodableBlock(
      startTime: startTime,
      endTime: endTime,
      micAudioFile: micFile,
      systemAudioFile: systemFile
    )
  }
}

/// A document model that holds transcript lines in time order.
class TranscriptDocument: ReferenceFileDocument, @unchecked Sendable, ObservableObject {
  /// The document title (shown in the titlebar).
  @Published var title: String = "Untitled"

  /// The transcript lines, maintained in time order.
  @Published private(set) var lines: [TranscriptLine] = []

  @Published var playingLineIds: [UInt64] = []

  /// The start time of the recording session.
  @Published var sessionStartTime: Date?

  /// The end time of the recording session.
  @Published var sessionEndTime: Date?

  private var recordingBlocks: [RecordingBlock] = []
  private nonisolated let recordingBlocksLock = NSLock()
  private var playbackStartOffset: Int = 0
  private var playbackEndOffset: Int = 0
  private var currentPlaybackOffset: Int = 0
  private var reachedEnd: Bool = false
  @AppStorage("saveAudioToFile") private var saveAudioToFile: Bool = true

  @Published var lineIdsNeedingRendering: [UInt64: Bool] = [:]
  var selectedLineIds: [UInt64] = []
  private var previousSelectedLineIds: [UInt64] = []

  var attributedText: NSAttributedString = NSAttributedString()

  /// Thread-safe cached snapshot for background thread access during saves
  private nonisolated(unsafe) var cachedSnapshot: DocumentData?

  /// Lock for thread-safe access to cached snapshot
  private nonisolated let snapshotLock = NSLock()

  /// Undo manager for tracking document changes
  @MainActor
  var undoManager: UndoManager? {
    get { undoManagerValue }
    set { undoManagerValue = newValue }
  }

  private nonisolated(unsafe) var undoManagerValue: UndoManager?

  /// Echo cancellation setting (defaults to true)
  @MainActor
  private var enableEchoCancellation: Bool {
    UserDefaults.standard.object(forKey: "enableEchoCancellation") as? Bool ?? true
  }

  // MARK: - ReferenceFileDocument Conformance

  static var readableContentTypes: [UTType] {
    [UTType(exportedAs: "ai.moonshine.notetaker.transcript")]
  }

  nonisolated required init(configuration: ReadConfiguration) throws {
    // This initializer is called from a background thread when loading files.
    // We use nonisolated(unsafe) because we need to initialize @MainActor properties
    // during initialization, which is safe because the object isn't accessible yet.
    let lines: [TranscriptLine]
    let sessionStartTime: Date?
    let sessionEndTime: Date?
    var recordingBlocks: [RecordingBlock] = []
    var attributedText: NSAttributedString = NSAttributedString()

    // Load bundle format (directory)
    guard let fileWrapper = configuration.file.fileWrappers,
      let jsonWrapper = fileWrapper["transcript.json"],
      let jsonData = jsonWrapper.regularFileContents
    else {
      // New empty document
      self.title = "Untitled"
      lines = []
      sessionStartTime = nil
      sessionEndTime = nil
      self.lines = lines
      self.sessionStartTime = sessionStartTime
      self.sessionEndTime = sessionEndTime
      self.recordingBlocks = recordingBlocks
      self.attributedText = attributedText
      // Initialize the cached snapshot
      let snapshot = DocumentData(
        lines: lines,
        sessionStartTime: sessionStartTime,
        sessionEndTime: sessionEndTime,
        recordingBlocks: [],
        attributedText: attributedText
      )
      snapshotLock.lock()
      cachedSnapshot = snapshot
      snapshotLock.unlock()
      return
    }

    guard let documentData = try? JSONDecoder().decode(DocumentData.self, from: jsonData) else {
      throw CocoaError(.fileReadCorruptFile)
    }

    attributedText = documentData.attributedText

    // Load audio from WAV files
    for codableBlock in documentData.recordingBlocks {
      var block = RecordingBlock(
        startTime: codableBlock.startTime,
        endTime: codableBlock.endTime,
        micAudio: [],
        systemAudio: []
      )

      // Load mic audio
      if let micWrapper = fileWrapper[codableBlock.micAudioFile],
        let micData = micWrapper.regularFileContents
      {
        block.micAudio = try Self.loadWavData(micData)
      }

      // Load system audio
      if let systemWrapper = fileWrapper[codableBlock.systemAudioFile],
        let systemData = systemWrapper.regularFileContents
      {
        block.systemAudio = try Self.loadWavData(systemData)
      }

      recordingBlocks.append(block)
    }

    self.title = configuration.file.filename ?? "Untitled"
    lines = documentData.lines
    sessionStartTime = documentData.sessionStartTime
    sessionEndTime = documentData.sessionEndTime
    self.lines = lines
    self.sessionStartTime = sessionStartTime
    self.sessionEndTime = sessionEndTime
    self.recordingBlocks = recordingBlocks
    self.attributedText = documentData.attributedText

    // Initialize the cached snapshot
    var snapshot = DocumentData(
      lines: lines,
      sessionStartTime: sessionStartTime,
      sessionEndTime: sessionEndTime,
      recordingBlocks: recordingBlocks.compactMap { $0.codable },
      attributedText: attributedText
    )
    snapshot.recordingBlocksWithAudio = recordingBlocks
    snapshotLock.lock()
    cachedSnapshot = snapshot
    snapshotLock.unlock()
  }

  /// Initialize an empty transcript document.
  nonisolated init() {
    self.title = "Untitled"
    self.lines = []
    addDummyStartLine()
    self.sessionStartTime = nil
    self.sessionEndTime = nil
    self.recordingBlocks = []
    self.attributedText = NSAttributedString()
    var snapshot = DocumentData(
      lines: [],
      sessionStartTime: nil,
      sessionEndTime: nil,
      recordingBlocks: [],
      attributedText: attributedText
    )
    snapshot.recordingBlocksWithAudio = []
    snapshotLock.lock()
    cachedSnapshot = snapshot
    snapshotLock.unlock()
  }

  /// Initialize a transcript document with existing lines.
  nonisolated init(
    lines: [TranscriptLine], sessionStartTime: Date? = nil, sessionEndTime: Date? = nil,
    recordingBlocks: [RecordingBlock] = [],
    attributedText: NSAttributedString = NSAttributedString()
  ) {
    let sortedLines = lines.sorted { $0.startTime < $1.startTime }
    for line in sortedLines {
      lineIdsNeedingRendering[line.id] = true
    }

    self.title = "Untitled"
    self.lines = sortedLines
    self.sessionStartTime = sessionStartTime
    self.sessionEndTime = sessionEndTime
    self.attributedText = attributedText
    // Initialize cache directly (safe during initialization)
    var snapshot = DocumentData(
      lines: sortedLines,
      sessionStartTime: sessionStartTime,
      sessionEndTime: sessionEndTime,
      recordingBlocks: recordingBlocks.compactMap { $0.codable },
      attributedText: attributedText
    )
    snapshot.recordingBlocksWithAudio = recordingBlocks
    snapshotLock.lock()
    cachedSnapshot = snapshot
    snapshotLock.unlock()
  }

  nonisolated func snapshot(contentType: UTType) throws -> DocumentData {
    // SwiftUI's document saving can call this from a background thread.
    // Return the cached snapshot which is updated on the main actor.
    snapshotLock.lock()
    defer { snapshotLock.unlock() }

    guard let snapshot = cachedSnapshot else {
      // If no cached snapshot exists, create one (shouldn't happen in normal flow)
      throw CocoaError(.fileWriteUnknown)
    }

    return snapshot
  }

  /// Update the cached snapshot. Call this from the main actor whenever the document changes.
  @MainActor
  public func updateCachedSnapshot() {
    var snapshot = DocumentData(from: self)
    snapshot.recordingBlocksWithAudio = self.recordingBlocks
    snapshot.attributedText = self.attributedText
    snapshotLock.lock()
    cachedSnapshot = snapshot
    snapshotLock.unlock()
  }

  nonisolated func fileWrapper(snapshot: DocumentData, configuration: WriteConfiguration) throws
    -> FileWrapper
  {
    print("fileWrapper started")
    // This method is called from a background thread during document saving.
    // It only uses the snapshot parameter (which is already a value type),
    // so it doesn't need main actor isolation.
    var fileWrappers: [String: FileWrapper] = [:]

    // Get audio blocks from snapshot (non-Codable property)
    guard let audioBlocks = snapshot.recordingBlocksWithAudio else {
      print("No audio blocks found")
      throw CocoaError(.fileWriteUnknown)
    }

    // Create WAV files for each block
    var codableBlocks: [RecordingBlock.CodableBlock] = []

    if saveAudioToFile {
      for (index, block) in audioBlocks.enumerated() {
        let micFileName = "block_\(index)_mic.wav"
        let systemFileName = "block_\(index)_system.wav"

        // Create WAV file data (16-bit signed integer, 48KHz, mono)
        let micData = try Self.createWavData(block.micAudio, sampleRate: 48000)
        let systemData = try Self.createWavData(block.systemAudio, sampleRate: 48000)

        fileWrappers[micFileName] = FileWrapper(regularFileWithContents: micData)
        fileWrappers[systemFileName] = FileWrapper(regularFileWithContents: systemData)

        codableBlocks.append(
          RecordingBlock.CodableBlock(
            startTime: block.startTime,
            endTime: block.endTime,
            micAudioFile: micFileName,
            systemAudioFile: systemFileName
          ))
      }
    }
    // Create transcript.json with metadata
    let transcriptData = DocumentData(
      lines: snapshot.lines,
      sessionStartTime: snapshot.sessionStartTime,
      sessionEndTime: snapshot.sessionEndTime,
      recordingBlocks: codableBlocks,
      attributedText: snapshot.attributedText
    )

    let jsonData = try JSONEncoder().encode(transcriptData)
    fileWrappers["transcript.json"] = FileWrapper(regularFileWithContents: jsonData)

    print("fileWrapper finished")

    // Create directory wrapper
    return FileWrapper(directoryWithFileWrappers: fileWrappers)
  }

  func exportAudioAsWAV(to url: URL) throws {
    var audioData: [Float] = []
    for block in self.recordingBlocks {
      let mixedAudio = zip(block.micAudio, block.systemAudio).map { $0 + $1 }
      audioData.append(contentsOf: mixedAudio)
    }

    let wavData = try Self.createWavData(audioData, sampleRate: 48000)
    try wavData.write(to: url)
  }

  /// Helper to create WAV file data (16KHz, 16-bit signed integer, mono)
  nonisolated private static func createWavData(_ samples: [Float], sampleRate: Int) throws -> Data
  {
    let numChannels: UInt16 = 1
    let bitsPerSample: UInt16 = 16
    let bytesPerSample = bitsPerSample / 8
    let numSamples = samples.count

    let dataChunkSize = UInt32(numSamples * Int(numChannels) * Int(bytesPerSample))
    let fmtChunkSize: UInt32 = 16
    let fileSize = 4 + 4 + 4 + 4 + (4 + 4 + fmtChunkSize) + (4 + 4 + dataChunkSize)

    var data = Data()

    // RIFF header
    data.append("RIFF".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: UInt32(fileSize - 8).littleEndian) { Data($0) })
    data.append("WAVE".data(using: .ascii)!)

    // fmt chunk
    data.append("fmt ".data(using: .ascii)!)
    data.append(contentsOf: withUnsafeBytes(of: fmtChunkSize.littleEndian) { Data($0) })
    let audioFormat: UInt16 = 1  // PCM (uncompressed)
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

    // Convert Float samples to 16-bit signed integers
    // Clamp to [-1.0, 1.0] range and scale to Int16 range [-32768, 32767]
    var low: Float = -1.0
    var high: Float = 1.0
    var clampedSamples = [Float](repeating: 0, count: samples.count)
    vDSP_vclip(samples, 1, &low, &high, &clampedSamples, 1, vDSP_Length(samples.count))

    // Multiply by 32767.0
    var scale: Float = 32767.0
    vDSP_vsmul(clampedSamples, 1, &scale, &clampedSamples, 1, vDSP_Length(samples.count))

    // Convert Float to Int16
    var int16Samples = [Int16](repeating: 0, count: samples.count)
    vDSP_vfix16(clampedSamples, 1, &int16Samples, 1, vDSP_Length(samples.count))

    // Copy entire buffer to Data at once
    let sampleDataI16 = int16Samples.withUnsafeBytes { Data($0) }
    data.append(sampleDataI16)

    return data
  }

  /// Load audio samples from WAV file data
  /// Assumes 16-bit signed integer, mono, little-endian format
  nonisolated private static func loadWavData(_ data: Data) throws -> [Float] {
    guard data.count >= 44 else {  // Minimum WAV header size
      throw CocoaError(.fileReadCorruptFile)
    }

    // Parse RIFF header
    guard data.count >= 12,
      String(data: data[0..<4], encoding: .ascii) == "RIFF",
      String(data: data[8..<12], encoding: .ascii) == "WAVE"
    else {
      throw CocoaError(.fileReadCorruptFile)
    }

    // Find data chunk
    var dataStart = 12
    var foundDataChunk = false

    while dataStart + 8 <= data.count {
      let chunkId = String(data: data[dataStart..<dataStart + 4], encoding: .ascii) ?? ""
      let chunkSize = UInt32(
        littleEndian: data.withUnsafeBytes {
          $0.load(fromByteOffset: dataStart + 4, as: UInt32.self)
        })

      if chunkId == "data" {
        dataStart += 8  // Skip chunk ID and size
        foundDataChunk = true
        break
      }

      dataStart += 8 + Int(chunkSize)
      if chunkSize % 2 == 1 {
        dataStart += 1  // Pad byte
      }
    }

    guard foundDataChunk else {
      throw CocoaError(.fileReadCorruptFile)
    }

    // Extract 16-bit signed integer samples and convert to Float
    let sampleCount = (data.count - dataStart) / 2  // 2 bytes per sample

    let samples: [Float] = data.withUnsafeBytes { rawBuffer in
      let int16Ptr = rawBuffer.baseAddress!.advanced(by: dataStart).assumingMemoryBound(
        to: Int16.self)

      // Pre-allocate output array
      var floatSamples = [Float](repeating: 0, count: sampleCount)

      // Convert Int16 to Float (vectorized)
      vDSP_vflt16(int16Ptr, 1, &floatSamples, 1, vDSP_Length(sampleCount))

      // Divide by 32768.0 to normalize to [-1.0, 1.0]
      var divisor: Float = 32768.0
      vDSP_vsdiv(floatSamples, 1, &divisor, &floatSamples, 1, vDSP_Length(sampleCount))

      return floatSamples
    }
    return samples
  }

  func exportCaptionsAsSRT(to url: URL) throws {
    guard recordingBlocks.count > 0 else {
      throw CocoaError(.fileWriteUnknown)
    }
    var srtText = ""
    let startTime: Date = recordingBlocks[0].startTime
    var previousLineEndTime: Date = startTime
    var index = 1
    for line in lines {
      // Skip the dummy start line with id 0 and empty lines.
      if line.id == 0 || line.text.isEmpty {
        continue
      }

      // Make sure that lines are not overlapping in time.
      let lineStartTime = max(line.startTime, previousLineEndTime)
      let lineEndTime = line.startTime.addingTimeInterval(line.duration)
      previousLineEndTime = lineEndTime

      let lineStartRelativeTime = lineStartTime.timeIntervalSince(startTime)
      let lineEndRelativeTime = lineEndTime.timeIntervalSince(startTime)

      let lineStartHours = Int(lineStartRelativeTime / 3600)
      let lineStartMinutes = Int((lineStartRelativeTime.truncatingRemainder(dividingBy: 3600)) / 60)
      let lineStartSeconds = Int(lineStartRelativeTime.truncatingRemainder(dividingBy: 60))
      let lineStartMilliseconds = Int((lineStartRelativeTime - floor(lineStartRelativeTime)) * 1000)

      let lineEndHours = Int(lineEndRelativeTime / 3600)
      let lineEndMinutes = Int((lineEndRelativeTime.truncatingRemainder(dividingBy: 3600)) / 60)
      let lineEndSeconds = Int(lineEndRelativeTime.truncatingRemainder(dividingBy: 60))
      let lineEndMilliseconds = Int((lineEndRelativeTime - floor(lineEndRelativeTime)) * 1000)

      srtText += "\(index)\n"
      srtText +=
        String(
          format: "%02d:%02d:%02d,%03d", lineStartHours, lineStartMinutes, lineStartSeconds,
          lineStartMilliseconds)
      srtText += " --> "
      srtText +=
        String(
          format: "%02d:%02d:%02d,%03d", lineEndHours, lineEndMinutes, lineEndSeconds,
          lineEndMilliseconds) + "\n"
      srtText += "\(line.text)\n"
      index += 1
    }
    try srtText.write(to: url, atomically: true, encoding: .utf8)
  }

  func setAttributedText(_ newAttributedText: NSAttributedString) {
    // Ensure each line's text is updated to match the new attributed text. This is necessary because the text view may have been edited directly, and we need to update the lines array to reflect the changes.
    let lineIndexesById: [UInt64: Int] = lines.enumerated().reduce(into: [:]) { result, element in
      result[element.element.id] = element.offset
    }
    var foundLineIndexes: [Int: Bool] = Dictionary(
      uniqueKeysWithValues: (0..<lines.count).map { ($0, false) })
    newAttributedText.enumerateAttributes(
      in: NSRange(location: 0, length: newAttributedText.length), options: []
    ) { attributes, range, stop in
      if let metadata = attributes[.transcriptLineMetadata] as? Data,
        let lineMetadata = decodeMetadata(metadata)
      {
        if let index = lineIndexesById[lineMetadata.lineId] {
          let newText = newAttributedText.attributedSubstring(from: range).string
          lines[index].text = newText
          foundLineIndexes[index] = true
        }
      }
    }
    for (lineIndex, present) in foundLineIndexes {
      if !present {
        var updatedLine = lines[lineIndex]
        updatedLine.text = ""
      }
    }

    attributedText = newAttributedText
    DispatchQueue.main.async {
      self.updateCachedSnapshot()
    }
  }

  /// Total duration of the recording in seconds.
  @MainActor
  var totalDuration: TimeInterval {
    guard let start = sessionStartTime, let end = sessionEndTime else {
      return 0
    }
    return end.timeIntervalSince(start)
  }

  func addDummyStartLine() {
    let line = TranscriptLine(
      id: 0, text: "\n", startTime: Date(timeIntervalSince1970: 0), duration: 0,
      source: .systemAudio, hasSpeakerId: false, speakerIndex: 0)
    lineIdsNeedingRendering[line.id] = true
    lines.insert(line, at: 0)
  }

  /// Start a new recording session.
  @MainActor
  func startSession() {
    sessionStartTime = Date()
    sessionEndTime = nil
    // Keep existing lines instead of clearing them
    undoManager?.registerUndo(withTarget: self) { doc in }
    undoManager?.setActionName("Start Session")
    updateCachedSnapshot()
  }

  /// End the current recording session.
  @MainActor
  func endSession() {
    sessionEndTime = Date()
    updateCachedSnapshot()
  }

  /// Add a new transcript line, maintaining time order.
  /// - Parameter line: The transcript line to add
  @MainActor
  func addLine(_ line: TranscriptLine) {
    // Insert in sorted order by start time
    if let insertIndex = lines.firstIndex(where: { $0.startTime > line.startTime }) {
      lines.insert(line, at: insertIndex)
    } else {
      lines.append(line)
    }
    lineIdsNeedingRendering[line.id] = true
    normalizeLines()
    updateCachedSnapshot()
  }

  @MainActor
  func updateLine(id: UInt64, text: String, duration: TimeInterval, hasSpeakerId: Bool, speakerIndex: UInt32) {
    if let index = lines.firstIndex(where: { $0.id == id }) {
      var updatedLine = lines[index]
      updatedLine.text = text
      updatedLine.duration = duration
      updatedLine.hasSpeakerId = hasSpeakerId
      updatedLine.speakerIndex = speakerIndex
      lines[index] = updatedLine
      lines.sort { $0.startTime < $1.startTime }
      lineIdsNeedingRendering[id] = true
      normalizeLines()
      updateCachedSnapshot()
    }
  }

  @MainActor
  func getViewSegments() -> [TranscriptTextSegment] {
    var segments: [TranscriptTextSegment] = []
    for line in lines {
      segments.append(
        TranscriptTextSegment(
          text: line.text, metadata: TranscriptLineMetadata(lineId: line.id, userEdited: false)))
    }
    return segments
  }

  @MainActor
  func updateFromViewSegments(_ segments: [TranscriptTextSegment]) {
    for segment in segments {
      if let index = lines.firstIndex(where: { $0.id == segment.metadata.lineId }) {
        var updatedLine = lines[index]
        updatedLine.text = segment.text
        lines[index] = updatedLine
      } else {
        print("Shouldn't get here: new line \(segment.text) with id \(segment.metadata.lineId)")
      }
    }
    normalizeLines()
    updateCachedSnapshot()
  }

  @MainActor
  func normalizeLines() {
    lines.sort { $0.startTime < $1.startTime }
    var idToLineMap: [UInt64: Int] = [:]
    var mergedLines: [TranscriptLine] = []
    // Merge together lines with the same id.
    for line in lines {
      if idToLineMap[line.id] == nil {
        idToLineMap[line.id] = mergedLines.count
        mergedLines.append(line)
      } else {
        let index = idToLineMap[line.id]!
        mergedLines[index].text += line.text
      }
    }
    // Only perform overlap checking if echo cancellation is enabled
    if enableEchoCancellation {
      var secondToLinesMap: [Int: [TranscriptLine]] = [:]
      for line in mergedLines {
        let floorStartTime = Int(line.startTime.timeIntervalSince1970)
        let ceilEndTime = Int(line.endTime.timeIntervalSince1970)
        for second in floorStartTime...ceilEndTime {
          if secondToLinesMap[second] == nil {
            secondToLinesMap[second] = []
          }
          secondToLinesMap[second]!.append(line)
        }
      }
      var echoCancelledLines: [TranscriptLine] = []
      var lineIndex = 0
      for line in mergedLines {
        if line.source != .microphone {
          echoCancelledLines.append(line)
          lineIndex += 1
          continue
        }
        let floorStartTime = Int(line.startTime.timeIntervalSince1970)
        let ceilEndTime = Int(line.endTime.timeIntervalSince1970)
        var overlapsTooMuch = false
        for second in floorStartTime...ceilEndTime {
          for candidateLine in secondToLinesMap[second] ?? [] {
            if candidateLine.source != .systemAudio || candidateLine.id == line.id
              || candidateLine.text.isEmpty
            {
              continue
            }
            let overlapStart = max(
              line.startTime.timeIntervalSince1970, candidateLine.startTime.timeIntervalSince1970)
            let overlapEnd = min(
              line.endTime.timeIntervalSince1970, candidateLine.endTime.timeIntervalSince1970)
            let overlapDuration = max(0, overlapEnd - overlapStart)
            let overlapProportion = overlapDuration / line.duration
            // If more than 30% of the line is overlapped with a system audio line, cancel the line.
            if overlapProportion > 0.3 {
              overlapsTooMuch = true
              break
            }
          }
          if overlapsTooMuch {
            break
          }
        }
        if !overlapsTooMuch {
          echoCancelledLines.append(line)
        }
      }

      lines = echoCancelledLines
    } else {
      lines = mergedLines
    }
  }

  func startNewRecordingBlock() {
    recordingBlocksLock.lock()
    defer { recordingBlocksLock.unlock() }
    recordingBlocks.append(
      RecordingBlock(startTime: Date(), endTime: Date(), micAudio: [], systemAudio: []))
  }

  func endCurrentRecordingBlock() {
    recordingBlocksLock.lock()
    defer { recordingBlocksLock.unlock() }
    recordingBlocks[recordingBlocks.count - 1].endTime = Date()
  }

  func addMicAudio(_ audio: [Float]) {
    recordingBlocksLock.lock()
    defer { recordingBlocksLock.unlock() }
    recordingBlocks[recordingBlocks.count - 1].micAudio.append(contentsOf: audio)
  }

  func addSystemAudio(_ audio: [Float]) {
    recordingBlocksLock.lock()
    defer { recordingBlocksLock.unlock() }
    recordingBlocks[recordingBlocks.count - 1].systemAudio.append(contentsOf: audio)
  }

  func getBlockIndexAndOffset(index: Int) -> (Int, Int) {
    var blockStartIndex = 0
    for (blockIndex, block) in recordingBlocks.enumerated() {
      if index < blockStartIndex + block.audioCount {
        return (blockIndex, index - blockStartIndex)
      }
      blockStartIndex += block.audioCount
    }
    let lastBlock = recordingBlocks[recordingBlocks.count - 1]
    return (recordingBlocks.count - 1, lastBlock.audioCount)
  }

  func getGlobalOffset(blockIndex: Int, blockOffset: Int) -> Int {
    var globalOffset = 0
    for i in 0..<blockIndex {
      globalOffset += recordingBlocks[i].audioCount
    }
    globalOffset += blockOffset
    return globalOffset
  }

  func getGlobalOffsetFromTime(time: Date) -> Int {
    for (blockIndex, block) in recordingBlocks.enumerated() {
      if time >= block.startTime && time <= block.endTime {
        let relativeTime = time.timeIntervalSince(block.startTime)
        return getGlobalOffset(blockIndex: blockIndex, blockOffset: Int(relativeTime * 48000.0))
      }
    }
    return 0
  }

  func getLineIdsForCurrentTime(currentGlobalOffset: Int) -> [UInt64] {
    let (currentBlockIndex, currentBlockOffset) = getBlockIndexAndOffset(index: currentGlobalOffset)
    let currentTime: Date =
      recordingBlocks[currentBlockIndex].startTime
      + TimeInterval(Double(currentBlockOffset) / 48000.0)
    var lineIds: [UInt64] = []
    for line in lines {
      if currentTime >= line.startTime && currentTime <= line.endTime {
        lineIds.append(line.id)
      }
    }
    return lineIds
  }

  func getNextAudioData(length: UInt32) -> ([Float], [UInt64], Bool) {
    recordingBlocksLock.lock()
    defer { recordingBlocksLock.unlock() }

    if self.reachedEnd {
      return ([], [], true)
    }

    let (startBlockIndex, startBlockOffset) = getBlockIndexAndOffset(index: currentPlaybackOffset)
    let (endBlockIndex, endBlockOffset) = getBlockIndexAndOffset(
      index: currentPlaybackOffset + Int(length))
    var micAudio: [Float] = []
    var systemAudio: [Float] = []
    var currentGlobalOffset = currentPlaybackOffset
    for blockIndex in startBlockIndex...endBlockIndex {
      let currentStartOffset: Int
      if blockIndex == startBlockIndex {
        currentStartOffset = startBlockOffset
      } else {
        currentStartOffset = 0
      }
      let currentEndOffset: Int
      if blockIndex == endBlockIndex {
        currentEndOffset = endBlockOffset
      } else {
        currentEndOffset = recordingBlocks[blockIndex].audioCount
      }
      let micStartOffset = min(currentStartOffset, recordingBlocks[blockIndex].micAudio.count)
      let micEndOffset = max(
        min(currentEndOffset, recordingBlocks[blockIndex].micAudio.count), micStartOffset)
      let systemStartOffset = min(currentStartOffset, recordingBlocks[blockIndex].systemAudio.count)
      let systemEndOffset = max(
        min(currentEndOffset, recordingBlocks[blockIndex].systemAudio.count), systemStartOffset)
      micAudio.append(
        contentsOf: recordingBlocks[blockIndex].micAudio[micStartOffset..<micEndOffset])
      systemAudio.append(
        contentsOf: recordingBlocks[blockIndex].systemAudio[systemStartOffset..<systemEndOffset])
      currentGlobalOffset += currentEndOffset - currentStartOffset
    }
    if playbackEndOffset != -1 {
      self.reachedEnd = currentGlobalOffset >= playbackEndOffset
    } else {
      let lastBlockIndex = recordingBlocks.count - 1
      let lastBlock = recordingBlocks[lastBlockIndex]
      let lastBlockSize = max(lastBlock.micAudio.count, lastBlock.systemAudio.count)
      let globalEndOffset = getGlobalOffset(blockIndex: lastBlockIndex, blockOffset: lastBlockSize)
      self.reachedEnd = currentGlobalOffset >= globalEndOffset
    }
    if micAudio.count < length {
      micAudio.append(contentsOf: Array(repeating: 0.0, count: Int(length) - micAudio.count))
    } else if micAudio.count > length {
      micAudio = Array(micAudio.prefix(Int(length)))
    }
    if systemAudio.count < length {
      systemAudio.append(contentsOf: Array(repeating: 0.0, count: Int(length) - systemAudio.count))
    } else if systemAudio.count > length {
      systemAudio = Array(systemAudio.prefix(Int(length)))
    }
    let lineIds = getLineIdsForCurrentTime(currentGlobalOffset: currentGlobalOffset)
    if !self.reachedEnd {
      currentPlaybackOffset += Int(length)
    }
    let mixedAudio = zip(micAudio, systemAudio).map { $0 + $1 }
    return (mixedAudio, lineIds, self.reachedEnd)
  }

  func setPlaybackRange(startOffset: Int, endOffset: Int) {
    playbackStartOffset = startOffset
    playbackEndOffset = endOffset
    currentPlaybackOffset = startOffset
    reachedEnd = false
  }

  func resetCurrentPlaybackOffset() {
    currentPlaybackOffset = playbackStartOffset
    reachedEnd = false
  }

  func getTimeRangeFromLineIds(lineIds: [UInt64]) -> (Date?, Date?) {
    if lineIds.count == 0 {
      return (Date(), Date())
    }
    var startTime: Date? = nil
    var endTime: Date? = nil
    for lineId in lineIds {
      if let index = lines.firstIndex(where: { $0.id == lineId }) {
        if startTime == nil || lines[index].startTime < startTime! {
          startTime = lines[index].startTime
        }
        if endTime == nil || lines[index].endTime > endTime! {
          endTime = lines[index].endTime
        }
      }
    }
    return (startTime, endTime)
  }

  func setPlaybackRangeFromLineIds(lineIds: [UInt64]) {
    if lineIds == previousSelectedLineIds {
      return
    }
    previousSelectedLineIds = lineIds
    if lineIds.isEmpty {
      setPlaybackRange(startOffset: 0, endOffset: -1)
      resetCurrentPlaybackOffset()
      return
    }
    let (startTime, endTime) = getTimeRangeFromLineIds(lineIds: lineIds)
    if startTime == nil || endTime == nil {
      setPlaybackRange(startOffset: 0, endOffset: -1)
      return
    }
    let startOffset = getGlobalOffsetFromTime(time: startTime!)
    let endOffset = getGlobalOffsetFromTime(time: endTime!)
    setPlaybackRange(startOffset: startOffset, endOffset: endOffset)
    resetCurrentPlaybackOffset()
  }

  func hasAudioData() -> Bool {
    recordingBlocksLock.lock()
    defer { recordingBlocksLock.unlock() }
    return recordingBlocks.count > 0
  }

}

// MARK: - Codable Support for Persistence

extension TranscriptDocument {
  /// Codable representation of the document for save/load.
  struct DocumentData {
    let lines: [TranscriptLine]
    let recordingBlocks: [RecordingBlock.CodableBlock]  // Only metadata, not audio
    let sessionStartTime: Date?
    let sessionEndTime: Date?
    let version: Int  // For future compatibility

    // Non-Codable: audio data for saving (excluded from JSON)
    var recordingBlocksWithAudio: [RecordingBlock]? = nil

    var attributedText: NSAttributedString = NSAttributedString()

    @MainActor
    init(from document: TranscriptDocument) {
      self.lines = document.lines
      self.recordingBlocks = []  // Will be populated during save
      self.sessionStartTime = document.sessionStartTime
      self.sessionEndTime = document.sessionEndTime
      self.version = 2
      self.recordingBlocksWithAudio = document.recordingBlocks
      self.attributedText = document.attributedText
    }

    // Nonisolated initializer for use from background threads
    nonisolated init(
      lines: [TranscriptLine], sessionStartTime: Date?, sessionEndTime: Date?,
      recordingBlocks: [RecordingBlock.CodableBlock],
      attributedText: NSAttributedString = NSAttributedString()
    ) {
      self.lines = lines
      self.recordingBlocks = recordingBlocks
      self.sessionStartTime = sessionStartTime
      self.sessionEndTime = sessionEndTime
      self.version = 2
      self.recordingBlocksWithAudio = nil
      self.attributedText = attributedText
    }
  }
}

// MARK: - Custom Codable Implementation

extension TranscriptDocument.DocumentData: Codable {
  enum CodingKeys: String, CodingKey {
    case lines
    case recordingBlocks
    case sessionStartTime
    case sessionEndTime
    case version
    case attributedText
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(lines, forKey: .lines)
    try container.encode(recordingBlocks, forKey: .recordingBlocks)
    try container.encode(sessionStartTime, forKey: .sessionStartTime)
    try container.encode(sessionEndTime, forKey: .sessionEndTime)
    try container.encode(version, forKey: .version)
    // Convert NSAttributedString to archived data to preserve all attributes (including custom ones)
    let archivedData = try NSKeyedArchiver.archivedData(
      withRootObject: attributedText,
      requiringSecureCoding: false
    )
    try container.encode(archivedData, forKey: .attributedText)
    // recordingBlocksWithAudio is intentionally excluded
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    lines = try container.decode([TranscriptLine].self, forKey: .lines)
    recordingBlocks = try container.decode(
      [RecordingBlock.CodableBlock].self, forKey: .recordingBlocks)
    sessionStartTime = try container.decodeIfPresent(Date.self, forKey: .sessionStartTime)
    sessionEndTime = try container.decodeIfPresent(Date.self, forKey: .sessionEndTime)
    version = try container.decode(Int.self, forKey: .version)
    recordingBlocksWithAudio = nil  // Not loaded from JSON
    // Decode archived data and convert back to NSAttributedString (preserves all attributes)
    if let archivedData = try container.decodeIfPresent(Data.self, forKey: .attributedText) {
      // Try NSKeyedUnarchiver first (preserves all custom attributes)
      // Using deprecated API as it's the most reliable for NSAttributedString with custom attributes
      if let unarchived = try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(archivedData)
        as? NSAttributedString
      {
        attributedText = unarchived
      } else {
        // Fallback: try legacy RTF format for backward compatibility
        if let rtfString = try? NSAttributedString(
          data: archivedData,
          options: [.documentType: NSAttributedString.DocumentType.rtf],
          documentAttributes: nil
        ) {
          attributedText = rtfString
        } else {
          attributedText = NSAttributedString()
        }
      }
    } else {
      attributedText = NSAttributedString()
    }
  }
}

extension String {
  func differenceRanges(from old: String) -> (
    insertions: [Range<String.Index>], deletions: [Range<String.Index>]
  ) {
    let diff = self.difference(from: old)

    var insertionOffsets: [Int] = []
    var deletionOffsets: [Int] = []

    for change in diff {
      switch change {
      case .insert(let offset, _, _):
        insertionOffsets.append(offset)
      case .remove(let offset, _, _):
        deletionOffsets.append(offset)
      }
    }

    // Convert to contiguous ranges
    func offsetsToRanges(_ offsets: [Int], in string: String) -> [Range<String.Index>] {
      guard !offsets.isEmpty else { return [] }
      let sorted = offsets.sorted()
      var ranges: [Range<String.Index>] = []
      var start = sorted[0]
      var end = start

      for offset in sorted.dropFirst() {
        if offset == end + 1 {
          end = offset
        } else {
          let startIdx = string.index(string.startIndex, offsetBy: start)
          let endIdx = string.index(string.startIndex, offsetBy: end + 1)
          ranges.append(startIdx..<endIdx)
          start = offset
          end = offset
        }
      }
      // Final range
      let startIdx = string.index(string.startIndex, offsetBy: start)
      let endIdx = string.index(string.startIndex, offsetBy: end + 1)
      ranges.append(startIdx..<endIdx)

      return ranges
    }

    return (
      offsetsToRanges(insertionOffsets, in: self),
      offsetsToRanges(deletionOffsets, in: old)
    )
  }
}
