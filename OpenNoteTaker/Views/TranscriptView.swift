/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A view that displays transcript text in an editable TextEditor.
*/

import SwiftUI

/// A view that displays transcript text in an editable TextEditor.
struct TranscriptView: View {
    @ObservedObject var document: TranscriptDocument
    @State private var attributedText: NSAttributedString = NSAttributedString()
    @State private var isUpdatingFromDocument = false
    
    var body: some View {
        ProvenanceTrackingTextEditor(attributedText: $attributedText)
            .font(.body)
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
            .onAppear {
                // Initialize text content from document
                let segments = document.getViewSegments()
                attributedText = makeAttributedString(from: segments)
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
        let newAttributedText = makeAttributedString(from: documentSegments)
        
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
}

