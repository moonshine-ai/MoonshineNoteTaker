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
    @State private var isUserEditing = false
    
    var body: some View {
        ProvenanceTrackingTextEditor(attributedText: $attributedText)
            .font(.body)
            .padding()
            .onChange(of: attributedText) { oldValue, newValue in
                if !isUpdatingFromDocument {
                    isUserEditing = true            
                    let segments = extractSegments(from: newValue)
                    document.updateFromViewSegments(segments)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        isUserEditing = false
                    }
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

    private func updateAttributedTextFromDocument() {
        if !isUserEditing && !isUpdatingFromDocument {
            isUpdatingFromDocument = true

            let segments = document.getViewSegments()
            let newText = makeAttributedString(from: segments)
            attributedText = newText
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isUpdatingFromDocument = false
            }
        }
    }
}

