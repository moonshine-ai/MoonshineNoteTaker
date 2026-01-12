/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A view that displays transcript lines in a scrollable list.
*/

import SwiftUI

/// A view that displays transcript lines vertically stacked with timestamps.
struct TranscriptView: View {
    @ObservedObject var document: TranscriptDocument
    
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(document.lines.filter { !$0.text.isEmpty }) { line in
                    TranscriptLineView(line: line, sessionStartTime: document.sessionStartTime)
                }
            }
            .padding()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A view that displays a single transcript line with timestamp.
struct TranscriptLineView: View {
    let line: TranscriptLine
    let sessionStartTime: Date?
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Source icon on the left
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .leading)
            
            // Time label
            Text(formattedTime)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            
            // Transcript text on the right
            Text(line.text)
                .font(.body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
    
    /// Returns the SF Symbol name for the source icon.
    private var iconName: String {
        switch line.source {
        case .microphone:
            return "mic.fill"
        case .systemAudio:
            return "speaker.wave.2.fill"
        }
    }
    
    /// Format the start time as HH:MM:SS relative to session start.
    private var formattedTime: String {
        guard let sessionStart = sessionStartTime else {
            return formatTimeInterval(line.startTime)
        }
        
        // Calculate absolute time by adding startTime to session start
        let absoluteTime = sessionStart.addingTimeInterval(line.startTime)
        return formatDate(absoluteTime)
    }
    
    /// Format a Date as HH:MM:SS.
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
    
    /// Format a TimeInterval as HH:MM:SS.
    private func formatTimeInterval(_ interval: TimeInterval) -> String {
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }
}

