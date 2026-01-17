/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A view that displays transcript text in an editable TextEditor.
*/

import SwiftUI

/// Observable object to handle zoom actions from menu commands
@MainActor
class ZoomHandler: ObservableObject {
    static let shared = ZoomHandler()
    
    var zoomIn: (() -> Void)?
    var zoomOut: (() -> Void)?
    var zoomReset: (() -> Void)?
    
    private init() {}
}

let defaultFontSize: Double = 13.0

/// A view that displays transcript text in an editable TextEditor.
struct TranscriptView: View {
    @ObservedObject var document: TranscriptDocument
    @State private var attributedText: NSAttributedString = NSAttributedString()
    @State private var isUpdatingFromDocument = false
    @AppStorage("textViewFontSize") private var fontSize: Double = defaultFontSize
    @EnvironmentObject var zoomHandler: ZoomHandler
    
    var body: some View {
        ProvenanceTrackingTextEditor(attributedText: $attributedText, fontSize: fontSize)
            .font(.body)
            .padding(.top, 4)
            .onChange(of: attributedText) { oldValue, newValue in
                // Only update document if this change didn't come from a document update
                if !isUpdatingFromDocument {
                    updateDocumentFromAttributedText(newValue)
                }
            }
            .onChange(of: document.lines) { oldLines, newLines in
                updateAttributedTextFromDocument()
            }
            .onChange(of: document.lines.last?.id) { oldId, newId in
                updateAttributedTextFromDocument()
            }
            .onChange(of: document.lines.last?.text) { oldText, newText in
                updateAttributedTextFromDocument()
            }
            .onChange(of: document.playingLineIds) { oldLineIds, newLineIds in
                updateAttributedTextFromDocument()
            }
            .onAppear {
                // Initialize text content from document
                let segments = document.getViewSegments()
                attributedText = makeAttributedString(from: segments, playingLineIds: document.playingLineIds, fontSize: fontSize)
                
                // Register zoom handlers
                zoomHandler.zoomIn = { self.zoomIn() }
                zoomHandler.zoomOut = { self.zoomOut() }
                zoomHandler.zoomReset = { self.zoomReset() }
            }
            .onChange(of: fontSize) { oldValue, newValue in
                // Re-register handlers when view updates (in case of view recreation)
                zoomHandler.zoomIn = { self.zoomIn() }
                zoomHandler.zoomOut = { self.zoomOut() }
                zoomHandler.zoomReset = { self.zoomReset() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Update the document from the attributed text, but only if the content actually differs.
    private func updateDocumentFromAttributedText(_ newAttributedText: NSAttributedString) {
        let viewSegments = extractSegments(from: newAttributedText)
        let documentSegments = document.getViewSegments()
        
        // Compare segments to see if they're actually different
        guard segmentsDiffer(viewSegments, documentSegments) else {
            // Content is the same, no update needed
            return
        }
        
        // Content differs, update the document
        document.updateFromViewSegments(viewSegments)
    }
    
    /// Update the attributed text from the document, but only if the content actually differs.
    private func updateAttributedTextFromDocument() {
        // Prevent circular updates
        guard !isUpdatingFromDocument else { return }
        
        let documentSegments = document.getViewSegments()
        let newAttributedText = makeAttributedString(from: documentSegments, playingLineIds: document.playingLineIds, fontSize: fontSize)
        
        // Compare with current attributed text to avoid unnecessary updates
        // This prevents circular updates when the content is already in sync
        guard attributedText != newAttributedText else { return }
        
        // Set flag before updating to prevent onChange(of: attributedText) from firing
        isUpdatingFromDocument = true
        attributedText = newAttributedText
        
        // Reset flag after SwiftUI has processed the change
        // Use Task to ensure this happens on the next run loop, but without a fixed delay
        Task { @MainActor in
            isUpdatingFromDocument = false
        }
    }
    
    /// Compare two segment arrays to determine if they differ.
    private func segmentsDiffer(_ segments1: [TranscriptTextSegment], _ segments2: [TranscriptTextSegment]) -> Bool {
        // Quick length check
        guard segments1.count == segments2.count else { return true }
        
        // Compare each segment
        for (seg1, seg2) in zip(segments1, segments2) {
            if seg1.text != seg2.text || seg1.metadata.lineId != seg2.metadata.lineId {
                return true
            }
        }
        
        return false
    }
    
    // Zoom functions
    func zoomIn() {
        fontSize = min(fontSize + 1.0, 72.0)
        updateAttributedTextFromDocument()
    }
    
    func zoomOut() {
        fontSize = max(fontSize - 1.0, 8.0)
        updateAttributedTextFromDocument()
    }
    
    func zoomReset() {
        fontSize = defaultFontSize
        updateAttributedTextFromDocument()
    }
}

