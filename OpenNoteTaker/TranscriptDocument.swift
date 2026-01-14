/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A document model that holds transcript lines in time order for display and persistence.
*/

import Foundation
import SwiftUI
import ScreenCaptureKit
import UniformTypeIdentifiers

/// Represents a single transcript line with timing information.
struct TranscriptLine: Identifiable, Codable, Equatable {
    /// Unique identifier for the line.
    let id: UInt64
    
    /// The transcribed text content.
    var text: String
    
    /// Start time of the line in wall clock time.
    let startTime: Date
    
    /// Duration of the line in seconds.
    let duration: TimeInterval
    
    /// End time of the line (startTime + duration).
    var endTime: Date {
        startTime.addingTimeInterval(duration)
    }
    
    enum Source: String, Codable, Equatable {
        case microphone
        case systemAudio
    }

    let source: Source
    
    init(id: UInt64, text: String, startTime: Date, duration: TimeInterval, source: TranscriptLine.Source) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.source = source
    }
}

/// A document model that holds transcript lines in time order.
class TranscriptDocument: @preconcurrency ReferenceFileDocument, @unchecked Sendable, ObservableObject {
    /// The document title (shown in the titlebar).
    @Published var title: String = "Untitled"
    
    /// The transcript lines, maintained in time order.
    @Published private(set) var lines: [TranscriptLine] = []
    
    /// The start time of the recording session.
    @Published var sessionStartTime: Date?
    
    /// The end time of the recording session.
    @Published var sessionEndTime: Date?
    
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
    
    // MARK: - ReferenceFileDocument Conformance
    
    static var readableContentTypes: [UTType] {
        [UTType(exportedAs: "ai.moonshine.opennotetaker.transcript")]
    }
    
    nonisolated required init(configuration: ReadConfiguration) throws {
        // This initializer is called from a background thread when loading files.
        // We use nonisolated(unsafe) because we need to initialize @MainActor properties
        // during initialization, which is safe because the object isn't accessible yet.
        let lines: [TranscriptLine]
        let sessionStartTime: Date?
        let sessionEndTime: Date?
        
        if let data = configuration.file.regularFileContents {
            if let document = Self.decode(from: data) {
                self.title = configuration.file.filename ?? "Untitled"
                lines = document.lines
                sessionStartTime = document.sessionStartTime
                sessionEndTime = document.sessionEndTime
                self.lines = lines
                self.sessionStartTime = sessionStartTime
                self.sessionEndTime = sessionEndTime
            } else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } else {
            // New empty document
            self.title = "Untitled"
            lines = []
            sessionStartTime = nil
            sessionEndTime = nil
            self.lines = lines
            self.sessionStartTime = sessionStartTime
            self.sessionEndTime = sessionEndTime
        }
        
        // Initialize the cached snapshot directly using captured values
        let snapshot = DocumentData(
            lines: lines,
            sessionStartTime: sessionStartTime,
            sessionEndTime: sessionEndTime
        )
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
    private func updateCachedSnapshot() {
        let snapshot = DocumentData(from: self)
        snapshotLock.lock()
        cachedSnapshot = snapshot
        snapshotLock.unlock()
    }
    
    nonisolated func fileWrapper(snapshot: DocumentData, configuration: WriteConfiguration) throws -> FileWrapper {
        // This method is called from a background thread during document saving.
        // It only uses the snapshot parameter (which is already a value type),
        // so it doesn't need main actor isolation.
        let data = try JSONEncoder().encode(snapshot)
        return FileWrapper(regularFileWithContents: data)
    }
    
    /// Total duration of the recording in seconds.
    @MainActor
    var totalDuration: TimeInterval {
        guard let start = sessionStartTime, let end = sessionEndTime else {
            return 0
        }
        return end.timeIntervalSince(start)
    }
    
    /// Initialize an empty transcript document.
    nonisolated init() {
        self.title = "Untitled"
        self.lines = []
        addDummyStartLine()
        self.sessionStartTime = nil
        self.sessionEndTime = nil
    }
    
    /// Initialize a transcript document with existing lines.
    /// - Parameters:
    ///   - lines: Array of transcript lines (will be sorted by start time)
    ///   - sessionStartTime: Optional session start time
    ///   - sessionEndTime: Optional session end time
    nonisolated init(lines: [TranscriptLine], sessionStartTime: Date? = nil, sessionEndTime: Date? = nil) {
        let sortedLines = lines.sorted { $0.startTime < $1.startTime }
        self.title = "Untitled"
        self.lines = sortedLines
        self.sessionStartTime = sessionStartTime
        self.sessionEndTime = sessionEndTime
        // Initialize cache directly (safe during initialization)
        let snapshot = DocumentData(
            lines: sortedLines,
            sessionStartTime: sessionStartTime,
            sessionEndTime: sessionEndTime
        )
        snapshotLock.lock()
        cachedSnapshot = snapshot
        snapshotLock.unlock()
    }

    func addDummyStartLine() {
        let line = TranscriptLine(id: 0, text: "\n", startTime: Date(timeIntervalSince1970: 0), duration: 0, source: .systemAudio)
        lines.insert(line, at: 0)
    }
    
    /// Start a new recording session.
    @MainActor
    func startSession() {
        sessionStartTime = Date()
        sessionEndTime = nil
        // Keep existing lines instead of clearing them
        undoManager?.registerUndo(withTarget: self) { doc in}
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
        updateCachedSnapshot()
    }
    
    /// Update an existing transcript line by ID.
    /// - Parameters:
    ///   - id: The ID of the line to update
    ///   - text: The new text content
    @MainActor
    func updateLine(id: UInt64, text: String) {
        if let index = lines.firstIndex(where: { $0.id == id }) {
            var updatedLine = lines[index]
            updatedLine.text = text
            lines[index] = updatedLine
            // Re-sort if needed (though startTime shouldn't change)
            lines.sort { $0.startTime < $1.startTime }
            updateCachedSnapshot()
        }
    }
    
    /// Remove a transcript line by ID.
    /// - Parameter id: The ID of the line to remove
    @MainActor
    func removeLine(id: UInt64) {
        lines.removeAll { $0.id == id }
        updateCachedSnapshot()
    }
    
    /// Get all lines as a single formatted text string.
    /// - Returns: All transcript lines joined with newlines
    @MainActor
    func getFullText() -> String {
        lines.map { $0.text }.joined(separator: "\n")
    }
    
    /// Get all non-empty lines as a single formatted text string.
    /// - Returns: All non-empty transcript lines joined with newlines
    @MainActor
    func getFilteredText() -> String {
        lines.filter { !$0.text.isEmpty }.map { $0.text }.joined(separator: "\n")
    }

    @MainActor
    func getViewSegments() -> [TranscriptTextSegment] {
        var segments: [TranscriptTextSegment] = []
        for line in lines {
            segments.append(TranscriptTextSegment(text: line.text, metadata: TranscriptLineMetadata(lineId: line.id, userEdited: false)))
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
        var newLines: [TranscriptLine] = []
        // Merge together lines with the same id.
        for line in lines {
            if idToLineMap[line.id] == nil {
                idToLineMap[line.id] = newLines.count
                newLines.append(line)
            } else {
                let index = idToLineMap[line.id]!
                newLines[index].text += line.text
            }
        }
        lines = newLines
    }
}

// MARK: - Codable Support for Persistence

extension TranscriptDocument {
    /// Codable representation of the document for save/load.
    struct DocumentData: Codable {
        let lines: [TranscriptLine]
        let sessionStartTime: Date?
        let sessionEndTime: Date?
        let version: Int // For future compatibility
        
        @MainActor
        init(from document: TranscriptDocument) {
            self.lines = document.lines
            self.sessionStartTime = document.sessionStartTime
            self.sessionEndTime = document.sessionEndTime
            self.version = 1
        }
        
        // Nonisolated initializer for use from background threads
        nonisolated init(lines: [TranscriptLine], sessionStartTime: Date?, sessionEndTime: Date?) {
            self.lines = lines
            self.sessionStartTime = sessionStartTime
            self.sessionEndTime = sessionEndTime
            self.version = 1
        }
    }
    
    /// Decode the document from data.
    /// - Parameter data: The encoded data
    /// - Returns: A new TranscriptDocument, or nil if decoding fails
    nonisolated static func decode(from data: Data) -> TranscriptDocument? {
        guard let documentData = try? JSONDecoder().decode(DocumentData.self, from: data) else {
            return nil
        }
        
        // Create document with all data in the initializer
        return TranscriptDocument(
            lines: documentData.lines,
            sessionStartTime: documentData.sessionStartTime,
            sessionEndTime: documentData.sessionEndTime
        )
    }
}

