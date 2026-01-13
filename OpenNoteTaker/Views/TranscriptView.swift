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
        // Use a slightly longer delay to ensure content is laid out
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.2)) {
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
    
    var body: some View {
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(filteredLines) { line in
                                TranscriptLineView(line: line)
                                    .id(line.id)
                            }
                        }
                        .padding()
                        
                        // Extra bottom padding to avoid recording button overlap
                        Spacer()
                            .frame(height: 50)
                            .id("bottom")
                            .background(
                                GeometryReader { scrollGeometry in
                                    // Use global coordinates to check if bottom anchor is visible
                                    let anchorGlobal = scrollGeometry.frame(in: .global)
                                    let viewportGlobal = geometry.frame(in: .global)
                                    // Check if anchor is visible in viewport (with generous margin)
                                    let isVisible = anchorGlobal.minY <= viewportGlobal.maxY + 50
                                    Color.clear.preference(
                                        key: ScrollOffsetPreferenceKey.self,
                                        value: isVisible ? 0 : 1000
                                    )
                                }
                            )
                    }
                }
                .coordinateSpace(name: "scroll")
                .onPreferenceChange(ScrollOffsetPreferenceKey.self) { value in
                    // If value is 0, the bottom anchor is visible (we're at/near bottom)
                    shouldAutoScroll = value < 10
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
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A view that displays a single transcript line.
struct TranscriptLineView: View {
    let line: TranscriptLine
    
    var body: some View {
        Text(line.text)
            .font(.body)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }    
}

