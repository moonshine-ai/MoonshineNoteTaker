/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A view that displays transcript lines in a scrollable list.
*/

import SwiftUI

/// A preference key to track scroll position.
struct ScrollOffsetPreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A view that displays transcript lines vertically stacked.
struct TranscriptView: View {
    @ObservedObject var document: TranscriptDocument
    @State private var shouldAutoScroll = true
    @State private var lastLineId: UInt64?
    @State private var lastLineText: String = ""
    
    private var filteredLines: [TranscriptLine] {
        document.lines.filter { !$0.text.isEmpty }
    }
    
    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
    
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(filteredLines) { line in
                        TranscriptLineView(line: line)
                            .id(line.id)
                    }
                    
                    // Invisible anchor at the bottom to detect scroll position
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                        .background(
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: ScrollOffsetPreferenceKey.self,
                                    value: geometry.frame(in: .named("scroll")).minY
                                )
                            }
                        )
                }
                .padding()
                .padding(.bottom, 120) // Extra bottom padding to avoid recording button overlap
            }
            .coordinateSpace(name: "scroll")
            .onPreferenceChange(ScrollOffsetPreferenceKey.self) { offset in
                // If we're near the bottom (within 170 points to account for padding), consider it "at bottom"
                shouldAutoScroll = offset < 170
            }
            .onChange(of: filteredLines.count) { oldCount, newCount in
                // Only auto-scroll if we were at the bottom and new lines were added
                if shouldAutoScroll && newCount > oldCount {
                    scrollToBottom(proxy: proxy)
                }
            }
            .onChange(of: filteredLines.last?.id) { oldId, newId in
                // Check if a new line was added (ID changed)
                if shouldAutoScroll, let newId = newId, newId != lastLineId {
                    scrollToBottom(proxy: proxy)
                    lastLineId = newId
                    if let lastLine = filteredLines.last {
                        lastLineText = lastLine.text
                    }
                } else if let newId = newId {
                    lastLineId = newId
                    if let lastLine = filteredLines.last {
                        lastLineText = lastLine.text
                    }
                }
            }
            .onChange(of: filteredLines.last?.text) { oldText, newText in
                // Check if the last line's text was updated
                if shouldAutoScroll, let newText = newText, newText != lastLineText {
                    scrollToBottom(proxy: proxy)
                    lastLineText = newText
                } else if let newText = newText {
                    lastLineText = newText
                }
            }
            .onAppear {
                // Initialize tracking state
                lastLineId = filteredLines.last?.id
                lastLineText = filteredLines.last?.text ?? ""
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A view that displays a single transcript line.
struct TranscriptLineView: View {
    let line: TranscriptLine
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Source icon on the left
            Image(systemName: iconName)
                .font(.system(size: 14))
                .foregroundColor(.secondary)
                .frame(width: 20, alignment: .leading)
            
            // Transcript text
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
}

