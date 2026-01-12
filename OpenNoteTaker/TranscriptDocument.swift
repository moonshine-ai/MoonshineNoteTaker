/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A document model that holds transcript lines in time order for display and persistence.
*/

import Foundation
import SwiftUI
import ScreenCaptureKit

/// Represents a single transcript line with timing information.
struct TranscriptLine: Identifiable, Codable, Equatable {
    /// Unique identifier for the line.
    let id: UInt64
    
    /// The transcribed text content.
    var text: String
    
    /// Start time of the line in seconds from the beginning of the recording.
    let startTime: TimeInterval
    
    /// Duration of the line in seconds.
    let duration: TimeInterval
    
    /// End time of the line (startTime + duration).
    var endTime: TimeInterval {
        startTime + duration
    }
    
    /// Timestamp when this line was created/received.
    let timestamp: Date

    enum Source: String, Codable, Equatable {
        case microphone
        case systemAudio
    }

    let source: Source
    
    init(id: UInt64, text: String, startTime: TimeInterval, duration: TimeInterval, timestamp: Date = Date(), source: TranscriptLine.Source) {
        self.id = id
        self.text = text
        self.startTime = startTime
        self.duration = duration
        self.timestamp = timestamp
        self.source = source
    }
}

/// A document model that holds transcript lines in time order.
@MainActor
class TranscriptDocument: ObservableObject {
    /// The transcript lines, maintained in time order.
    @Published private(set) var lines: [TranscriptLine] = []
    
    /// The start time of the recording session.
    @Published var sessionStartTime: Date?
    
    /// The end time of the recording session.
    @Published var sessionEndTime: Date?
    
    /// Total duration of the recording in seconds.
    var totalDuration: TimeInterval {
        guard let start = sessionStartTime, let end = sessionEndTime else {
            return 0
        }
        return end.timeIntervalSince(start)
    }
    
    /// Initialize an empty transcript document.
    init() {
        self.lines = []
        self.sessionStartTime = nil
        self.sessionEndTime = nil
    }
    
    /// Initialize a transcript document with existing lines.
    /// - Parameter lines: Array of transcript lines (will be sorted by start time)
    init(lines: [TranscriptLine]) {
        self.lines = lines.sorted { $0.startTime < $1.startTime }
    }
    
    /// Start a new recording session.
    func startSession() {
        sessionStartTime = Date()
        sessionEndTime = nil
        lines.removeAll()
    }
    
    /// End the current recording session.
    func endSession() {
        sessionEndTime = Date()
    }
    
    /// Add a new transcript line, maintaining time order.
    /// - Parameter line: The transcript line to add
    func addLine(_ line: TranscriptLine) {
        // Insert in sorted order by start time
        if let insertIndex = lines.firstIndex(where: { $0.startTime > line.startTime }) {
            lines.insert(line, at: insertIndex)
        } else {
            lines.append(line)
        }
    }
    
    /// Update an existing transcript line by ID.
    /// - Parameters:
    ///   - id: The ID of the line to update
    ///   - text: The new text content
    func updateLine(id: UInt64, text: String) {
        if let index = lines.firstIndex(where: { $0.id == id }) {
            var updatedLine = lines[index]
            updatedLine.text = text
            lines[index] = updatedLine
            // Re-sort if needed (though startTime shouldn't change)
            lines.sort { $0.startTime < $1.startTime }
        }
    }
    
    /// Remove a transcript line by ID.
    /// - Parameter id: The ID of the line to remove
    func removeLine(id: UInt64) {
        lines.removeAll { $0.id == id }
    }
    
    /// Get all lines as a single formatted text string.
    /// - Returns: All transcript lines joined with newlines
    func getFullText() -> String {
        lines.map { $0.text }.joined(separator: "\n")
    }
    
    /// Get lines within a specific time range.
    /// - Parameters:
    ///   - startTime: Start of the time range in seconds
    ///   - endTime: End of the time range in seconds
    /// - Returns: Array of lines within the time range
    func getLines(inTimeRange startTime: TimeInterval, endTime: TimeInterval) -> [TranscriptLine] {
        lines.filter { line in
            line.startTime >= startTime && line.startTime <= endTime
        }
    }
    
    /// Clear all transcript lines.
    func clear() {
        lines.removeAll()
        sessionStartTime = nil
        sessionEndTime = nil
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
    }
    
    /// Encode the document to data for saving.
    /// - Returns: Encoded data, or nil if encoding fails
    func encode() -> Data? {
        let data = DocumentData(from: self)
        return try? JSONEncoder().encode(data)
    }
    
    /// Decode the document from data.
    /// - Parameter data: The encoded data
    /// - Returns: A new TranscriptDocument, or nil if decoding fails
    static func decode(from data: Data) -> TranscriptDocument? {
        guard let documentData = try? JSONDecoder().decode(DocumentData.self, from: data) else {
            return nil
        }
        
        let document = TranscriptDocument(lines: documentData.lines)
        document.sessionStartTime = documentData.sessionStartTime
        document.sessionEndTime = documentData.sessionEndTime
        return document
    }
    
    /// Save the document to a file.
    /// - Parameter url: The file URL to save to
    /// - Throws: Error if saving fails
    func save(to url: URL) throws {
        guard let data = encode() else {
            throw NSError(domain: "TranscriptDocument", code: 1,
                         userInfo: [NSLocalizedDescriptionKey: "Failed to encode document"])
        }
        try data.write(to: url)
    }
    
    /// Load a document from a file.
    /// - Parameter url: The file URL to load from
    /// - Returns: A new TranscriptDocument, or nil if loading fails
    static func load(from url: URL) -> TranscriptDocument? {
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return decode(from: data)
    }
}

