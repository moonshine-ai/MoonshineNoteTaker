/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A view that displays transcript text in an editable TextEditor.
*/

import SwiftUI

let defaultFontSize: Double = 13.0

/// A view that displays transcript text in an editable TextEditor.
struct TranscriptView: View {
  @ObservedObject var document: TranscriptDocument
  @Binding var selectedLineIds: [UInt64]
  @State private var provenanceTextView: ProvenanceTextView? = nil
  @State private var provenanceTextStorage: ProvenanceTrackingTextStorage? = nil
  @AppStorage("fontSize") private var fontSize: Double = defaultFontSize
  @AppStorage("fontFamily") private var fontFamily: String = "System"
  private var font: NSFont {
    if fontFamily == "System" {
      return NSFont.systemFont(ofSize: fontSize)
    } else {
      return NSFont(name: fontFamily, size: fontSize) ?? NSFont.systemFont(ofSize: fontSize)
    }
  }
  var onFileDrag: ((NSDraggingInfo) -> Bool)?

  var body: some View {
    ProvenanceTrackingTextEditor(
      selectedLineIds: $selectedLineIds,
      fontSize: fontSize,
      onFileDrag: onFileDrag,
      textViewRef: $provenanceTextView,
      textStorageRef: $provenanceTextStorage,
      onTextViewReady: { textView in
          if document.attributedText.length > 0 {
              provenanceTextStorage?.append(document.attributedText)
          } else {
              // Needed for pre-release files that were saved before the attributedText was added.
              updateAttributedTextFromDocument()
          }
      },
      onAttributedTextChange: { newAttributedText in
        document.attributedText = NSAttributedString(attributedString: newAttributedText)
        document.updateCachedSnapshot()
      }
    )
    .font(Font.custom(fontFamily, size: fontSize))
    .padding(.top, 4)
    .onChange(of: document.lineIdsNeedingRendering) {
      updateAttributedTextFromDocument()
    }
    .onChange(of: document.playingLineIds) { oldLineIds, newLineIds in
      updatePlaybackHighlight(oldLineIds: oldLineIds, newLineIds: newLineIds)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  private func updatePlaybackHighlight(oldLineIds: [UInt64], newLineIds: [UInt64]) {
    guard
      let provenanceTextStorage = provenanceTextView?.textStorage as? ProvenanceTrackingTextStorage
    else { return }
    for lineId in oldLineIds {
      let range =
        provenanceTextStorage.getRangeForLineId(lineId: lineId) ?? NSRange(location: 0, length: 0)
      provenanceTextStorage.removeAttribute(.backgroundColor, range: range)
    }
    for lineId in newLineIds {
      let range =
        provenanceTextStorage.getRangeForLineId(lineId: lineId) ?? NSRange(location: 0, length: 0)
      provenanceTextStorage.addAttributes([.backgroundColor: NSColor.yellow], range: range)
    }
  }

  private func updateAttributedTextFromDocument() {
    let provenanceTextStorage = provenanceTextView?.textStorage as? ProvenanceTrackingTextStorage
    let lastUpdatedRange: NSRange? = nil
    var lineAlreadyExists: [UInt64: Bool] = [:]
    let fullRange = NSRange(location: 0, length: provenanceTextStorage?.length ?? 0)
    provenanceTextStorage?.enumerateAttribute(
      .transcriptLineMetadata,
      in: fullRange, options: []
    ) { value, range, stop in
      if let data = value as? Data, let existingMetadata = decodeMetadata(data) {
        lineAlreadyExists[existingMetadata.lineId] = true
      }
    }
    for line in document.lines.filter({ document.lineIdsNeedingRendering[$0.id] ?? false }) {
      let metadata = encodeMetadata(TranscriptLineMetadata(lineId: line.id, userEdited: false))!
      let newString: NSAttributedString = NSAttributedString(
        string: line.text, attributes: [.font: font, .transcriptLineMetadata: metadata])
      if !(lineAlreadyExists[line.id] ?? false) {
        provenanceTextStorage?.append(newString)
      } else {
        let oldRange =
          provenanceTextStorage?.getRangeForLineId(lineId: line.id)
          ?? NSRange(location: 0, length: 0)
        provenanceTextStorage?.replaceCharacters(in: oldRange, with: newString)
      }

      document.lineIdsNeedingRendering[line.id] = false
    }

    if let autoScrollView: AutoScrollView = provenanceTextView?.enclosingScrollView
      as? AutoScrollView, lastUpdatedRange != nil
    {
      if autoScrollView.isAtBottom {
        provenanceTextView?.scrollRangeToVisible(lastUpdatedRange!)
      }
    }
  }
}
