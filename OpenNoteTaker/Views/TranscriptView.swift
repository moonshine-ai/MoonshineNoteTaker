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
  @State private var selectionRange: NSRange? = nil
  @State private var isUpdatingFromDocument = false
  @State private var provenanceTextView: ProvenanceTextView? = nil
  @State private var provenanceTextStorage: ProvenanceTrackingTextStorage? = nil
  @AppStorage("textViewFontSize") private var fontSize: Double = defaultFontSize
  @EnvironmentObject var zoomHandler: ZoomHandler
  var onFileDrag: ((NSDraggingInfo) -> Bool)?

  var body: some View {
    ProvenanceTrackingTextEditor(
      selectionRange: $selectionRange,
      fontSize: fontSize,
      onFileDrag: onFileDrag,
      textViewRef: $provenanceTextView,
      textStorageRef: $provenanceTextStorage,
      onTextViewReady: { textView in
        // Initialize text content from document when textView is ready
        let segments = document.getViewSegments()
        let attributedText = makeAttributedString(
          from: segments, playingLineIds: document.playingLineIds, fontSize: fontSize)
        textView.textStorage?.setAttributedString(attributedText)
      }
    )
    .font(.body)
    .padding(.top, 4)
    .onChange(of: provenanceTextStorage?.backingStore ?? NSMutableAttributedString()) {
      oldValue, newValue in
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

  private func updateAttributedTextFromDocument() {
    // Prevent circular updates
    guard !isUpdatingFromDocument else { return }

    let provenanceTextStorage = provenanceTextView?.textStorage as? ProvenanceTrackingTextStorage

    var lastUpdatedRange: NSRange? = nil
    for line in document.lines.filter({ document.lineIdsNeedingRendering[$0.id] ?? false }) {
      var oldRange: NSRange = NSRange(location: provenanceTextStorage?.length ?? 0, length: 0)
      provenanceTextStorage?.enumerateAttribute(
        .transcriptLineMetadata,
        in: NSRange(location: 0, length: provenanceTextStorage?.length ?? 0), options: []
      ) { value, range, stop in
        if let data = value as? Data, let existingMetadata = decodeMetadata(data),
          existingMetadata.lineId == line.id
        {
          oldRange = range
          stop.pointee = true
        }
      }
      let newRange = NSRange(location: oldRange.location, length: line.text.count)
      let metadata = encodeMetadata(TranscriptLineMetadata(lineId: line.id, userEdited: false))!
      if oldRange.length > 0 {
        provenanceTextStorage?.replaceCharacters(in: oldRange, with: line.text)
          provenanceTextStorage?.setAttributes(
            [.transcriptLineMetadata : metadata],
            range: newRange)
      } else {
          var newString: NSMutableAttributedString = NSMutableAttributedString(string: line.text)
          newString.addAttributes([.transcriptLineMetadata : metadata], range: NSRange(location: 0, length: line.text.count))
            
        provenanceTextStorage?.insert(newString, at: oldRange.location)
      }
      document.lineIdsNeedingRendering[line.id] = false
    }

    // let oldAttributedText = provenanceTextStorage?.backingStore ?? NSAttributedString()

    // let documentSegments = document.getViewSegments()
    // let newAttributedText = makeAttributedString(
    //   from: documentSegments, playingLineIds: document.playingLineIds, fontSize: fontSize)

    // // Compare with current attributed text to avoid unnecessary updates
    // // This prevents circular updates when the content is already in sync
    // guard oldAttributedText != newAttributedText else { return }

    // let commonPrefixRange = getCommonPrefix(a: oldAttributedText, b: newAttributedText)
    // let commonPrefixLength = commonPrefixRange.length
    // let oldSuffixLength = oldAttributedText.length - commonPrefixLength
    // let oldSuffixRange = NSRange(location: commonPrefixLength, length: oldSuffixLength)
    // let oldSuffix = oldAttributedText.attributedSubstring(from: oldSuffixRange)
    // let newSuffixLength = newAttributedText.length - commonPrefixLength
    // let newSuffixRange = NSRange(location: commonPrefixLength, length: newSuffixLength)
    // let newSuffix = newAttributedText.attributedSubstring(from: newSuffixRange)

    // // Set flag before updating to prevent onChange(of: attributedText) from firing
    // isUpdatingFromDocument = true
    // provenanceTextStorage?.replaceCharacters(in: oldSuffixRange, with: newSuffix)
    // newAttributedText.enumerateAttribute(.transcriptLineMetadata, in: newSuffixRange, options: []) {
    //   value, range, _ in
    //   if let data = value as? Data, let metadata = decodeMetadata(data) {
    //     provenanceTextStorage?.addAttribute(
    //       .transcriptLineMetadata, value: data,
    //       range: NSRange(location: range.location, length: range.length))
    //   }
    // }

    if let autoScrollView: AutoScrollView? = provenanceTextView?.enclosingScrollView
      as? AutoScrollView ?? nil, lastUpdatedRange != nil
    {
      if autoScrollView?.isAtBottom ?? false {
        provenanceTextView?.scrollRangeToVisible(lastUpdatedRange!)
      }
    }

    Task { @MainActor in
      isUpdatingFromDocument = false
    }
  }

  /// Compare two segment arrays to determine if they differ.
  private func segmentsDiffer(
    _ segments1: [TranscriptTextSegment], _ segments2: [TranscriptTextSegment]
  ) -> Bool {
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
