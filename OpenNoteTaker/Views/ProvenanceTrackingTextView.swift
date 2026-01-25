import AppKit
import SwiftUI

// MARK: - Data Model

struct TranscriptLineMetadata: Codable, Equatable {
  let lineId: UInt64
  var userEdited: Bool

  /// Create a user-edited copy of this metadata
  func asUserEdited() -> TranscriptLineMetadata {
    var copy = self
    copy.userEdited = true
    return copy
  }
}

// MARK: - Custom Attribute Key

extension NSAttributedString.Key {
  static let transcriptLineMetadata = NSAttributedString.Key(
    "ai.moonshine.opennotetaker.transcriptLineMetadata")
}

// MARK: - Transcript Segment (Input/Output)

struct TranscriptTextSegment {
  let text: String
  let metadata: TranscriptLineMetadata
}

// MARK: - Metadata Encoding Helpers

func encodeMetadata(_ metadata: TranscriptLineMetadata) -> Data? {
  try? JSONEncoder().encode(metadata)
}

func decodeMetadata(_ data: Data) -> TranscriptLineMetadata? {
  try? JSONDecoder().decode(TranscriptLineMetadata.self, from: data)
}

func getMetadata(from attrs: [NSAttributedString.Key: Any]) -> TranscriptLineMetadata? {
  guard let data = attrs[.transcriptLineMetadata] as? Data else { return nil }
  return decodeMetadata(data)
}

class ProvenanceTrackingTextStorage: NSTextStorage {
  public let backingStore = NSMutableAttributedString()
  private var isEditing = false
  private var editedRangeStart: Int = 0
  private var editedRangeEnd: Int = 0

  override init() {
    super.init()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
  }

  override init(attributedString: NSAttributedString) {
    super.init()
    backingStore.setAttributedString(attributedString)
  }

  required init?(pasteboardPropertyList propertyList: Any, ofType type: NSPasteboard.PasteboardType)
  {
    super.init()
    // Try to create an NSAttributedString from the pasteboard data
    if let attributedString = NSAttributedString(pasteboardPropertyList: propertyList, ofType: type) {
      backingStore.setAttributedString(attributedString)
    } else if let stringData = propertyList as? Data,
      let string = String(data: stringData, encoding: .utf8)
    {
      // Fallback: try to create from plain string data
      backingStore.setAttributedString(NSAttributedString(string: string))
    } else if let string = propertyList as? String {
      // Fallback: try direct string conversion
      backingStore.setAttributedString(NSAttributedString(string: string))
    } else {
      // If we can't create anything meaningful, return nil
      return nil
    }
  }

  override var string: String {
    backingStore.string
  }

  override func attributes(at location: Int, effectiveRange range: NSRangePointer?)
    -> [NSAttributedString.Key: Any]
  {
    let attrs = backingStore.attributes(at: location, effectiveRange: range)
    return attrs
  }

  override func replaceCharacters(in range: NSRange, with str: String) {
    let delta = str.utf16.count - range.length

    // Get metadata to apply to new text (from the position being edited)
    let metadataForInsertion = getMetadataForInsertion(at: range)

    backingStore.replaceCharacters(in: range, with: str)

    // Apply metadata to the newly inserted text, marked as user-edited
    if str.count > 0, let sourceMeta = metadataForInsertion {
      let insertedRange = NSRange(location: range.location, length: str.utf16.count)
      let editedMeta = sourceMeta.asUserEdited()
      if let encoded = encodeMetadata(editedMeta) {
        backingStore.addAttribute(.transcriptLineMetadata, value: encoded, range: insertedRange)
      }
    }

    edited(.editedCharacters, range: range, changeInLength: delta)
  }

  override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
    // Preserve existing custom metadata attribute when NSTextView applies default formatting
    // Only preserve if attrs is provided (not nil) but doesn't include metadata
    // If attrs is nil, that's an explicit clear, so we respect that
    var mergedAttrs: [NSAttributedString.Key: Any]? = attrs

    if let attrs = attrs {
      // attrs is provided - check if we need to preserve existing metadata
      if range.location < backingStore.length {
        let checkRange = NSRange(
          location: range.location, length: min(range.length, backingStore.length - range.location))
        let attrsBefore = backingStore.attributes(at: checkRange.location, effectiveRange: nil)

        // If metadata exists and isn't being explicitly set in new attrs, preserve it
        if let existingMetadataData = attrsBefore[.transcriptLineMetadata] as? Data {
          if attrs[.transcriptLineMetadata] == nil {
            // New attrs don't include metadata, preserve existing
            var mutableAttrs = attrs  // Create mutable copy
            mutableAttrs[.transcriptLineMetadata] = existingMetadataData
            mergedAttrs = mutableAttrs
          }
        }
      }
    }

    // Apply merged attributes that include preserved metadata (or nil if clearing)
    backingStore.setAttributes(mergedAttrs, range: range)

    edited(.editedAttributes, range: range, changeInLength: 0)
  }

  private func getMetadataForInsertion(at range: NSRange) -> TranscriptLineMetadata? {
    guard backingStore.length > 0 else { return nil }

    // Prefer metadata from the character before the insertion point
    if range.location > 0 {
      let attrs = backingStore.attributes(at: range.location - 1, effectiveRange: nil)
      if let meta = getMetadata(from: attrs) {
        return meta
      }
    }

    // Fall back to character at/after insertion point
    if range.location < backingStore.length {
      let checkLocation = min(range.location, backingStore.length - 1)
      let attrs = backingStore.attributes(at: checkLocation, effectiveRange: nil)
      if let meta = getMetadata(from: attrs) {
        return meta
      }
    }

    // If replacing existing text, get metadata from what's being replaced
    if range.length > 0 && range.location < backingStore.length {
      let attrs = backingStore.attributes(at: range.location, effectiveRange: nil)
      if let meta = getMetadata(from: attrs) {
        return meta
      }
    }

    return nil
  }

  func getLineIdsFromRanges(selectedRanges: [NSRange]) -> [UInt64] {
    // No selection, return an empty result.
    if selectedRanges.count == 1 && selectedRanges[0].length == 0 {
      return []
    }
    var lineIds: [UInt64] = []
    for selectedRange in selectedRanges {
      backingStore.enumerateAttribute(.transcriptLineMetadata, in: selectedRange, options: []) {
        lineValue, lineRange, _ in
        if let lineValueJson = lineValue as? Data, let lineMetadata = decodeMetadata(lineValueJson)
        {
          lineIds.append(lineMetadata.lineId)
        }
      }
    }
    return lineIds
  }

  func getRangeForLineId(lineId: UInt64) -> NSRange {
    var result: NSRange = NSRange(location: backingStore.length, length: 0)
    backingStore.enumerateAttribute(
      .transcriptLineMetadata,
      in: NSRange(location: 0, length: backingStore.length), options: []
    ) { value, range, stop in
      if let data = value as? Data, let existingMetadata = decodeMetadata(data),
        existingMetadata.lineId == lineId
      {
        result = range
        stop.pointee = true
      }
    }
    return result
  }
}

// MARK: - Text View with Custom Storage

class ProvenanceTextView: NSTextView {
  var onSelectionChange: (([UInt64]) -> Void)?
  var onFileDrag: ((NSDraggingInfo) -> Bool)?  // Callback for file drags
  var onAttributedTextChange: ((NSAttributedString) -> Void)?
  private let bottomPadding: CGFloat = 50

  convenience init(frame: NSRect, textStorage: ProvenanceTrackingTextStorage) {
    let layoutManager = NSLayoutManager()
    textStorage.addLayoutManager(layoutManager)

    let textContainer = NSTextContainer(
      containerSize: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
    textContainer.widthTracksTextView = true
    textContainer.heightTracksTextView = false
    layoutManager.addTextContainer(textContainer)

    self.init(frame: frame, textContainer: textContainer)

    self.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

    // Set up to expand vertically
    self.isVerticallyResizable = true
    self.isHorizontallyResizable = false
    self.textContainerInset = NSSize(width: 0, height: 0)

    // Unregister all drag types so file drops pass through to SwiftUI handler
    // NSTextView automatically registers for file URLs and text, which interferes with SwiftUI's .onDrop
    self.unregisterDraggedTypes()
  }

  // Override drag methods to forward file drags to SwiftUI via callback
  private func isFileDrag(_ sender: NSDraggingInfo) -> Bool {
    let pasteboard = sender.draggingPasteboard
    return pasteboard.canReadObject(
      forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    // If it's a file drag and we have a callback, indicate we might accept it
    // but we'll actually handle it in performDragOperation
    if isFileDrag(sender), onFileDrag != nil {
      return .copy  // Return a valid operation so the drag continues
    }
    // For non-file drags, don't handle (we unregistered all types)
    return []
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    // Same as draggingEntered
    if isFileDrag(sender), onFileDrag != nil {
      return .copy
    }
    return []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    // If it's a file drag, call the callback to let SwiftUI handle it
    if isFileDrag(sender), let callback = onFileDrag {
      return callback(sender)
    }
    // Never perform drag operation for non-files
    return false
  }

  // Override pasteboard reading to prevent file URLs from being inserted as text
  override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool
  {
    // Allow text/string types through (for paste operations)
    if type == .string || type == NSPasteboard.PasteboardType("NSStringPboardType") {
      return super.readSelection(from: pboard, type: type)
    }

    // Check if this is a file URL pasteboard type (for drag and drop)
    if pboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) {
      // Don't read file URLs - let SwiftUI handle them
      return false
    }

    // For other types, use default behavior
    return super.readSelection(from: pboard, type: type)
  }

  override func setSelectedRange(
    _ charRange: NSRange, affinity: NSSelectionAffinity, stillSelecting: Bool
  ) {
    super.setSelectedRange(charRange, affinity: affinity, stillSelecting: stillSelecting)
    if !stillSelecting {
      guard let provenanceTextStorage = self.textStorage as? ProvenanceTrackingTextStorage else {
        return
      }
      let selectedRanges = self.selectedRanges.map { $0.rangeValue }
      if selectedRanges.count == 1 && selectedRanges[0].length == 0 {
        onSelectionChange?([])
        return
      }
      let lineIds = provenanceTextStorage.getLineIdsFromRanges(selectedRanges: selectedRanges)
      onSelectionChange?(lineIds)
    }
  }

  override func layout() {
    super.layout()
    DispatchQueue.main.async { [weak self] in
      self?.adjustFrameForBottomPadding()
    }
  }

  override func mouseMoved(with event: NSEvent) {
    // If a higher-level view (like a SwiftUI button) has already set a cursor,
    // don't override it. Check if current cursor is not I-beam.
    if NSCursor.current != NSCursor.iBeam {
      // Cursor already set by higher-level view (e.g., button's onHover),
      // don't reset it to I-beam
      return
    }

    // Otherwise, allow normal NSTextView cursor behavior
    super.mouseMoved(with: event)
  }

  override func didChangeText() {
    super.didChangeText()
    if let onAttributedTextChange = onAttributedTextChange {
      onAttributedTextChange(self.attributedString())
    }
  }

  private func adjustFrameForBottomPadding() {
    guard let textContainer = self.textContainer,
      let layoutManager = textContainer.layoutManager
    else { return }

    // Calculate the actual content height
    let usedRect = layoutManager.usedRect(for: textContainer)
    let contentHeight = usedRect.height

    // Set frame height to content height + bottom padding
    let newHeight = contentHeight + bottomPadding
    if abs(frame.height - newHeight) > 0.1 {
      setFrameSize(NSSize(width: frame.width, height: newHeight))
    }
  }
}

class AutoScrollView: NSScrollView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // Unregister drag types so file drops pass through to SwiftUI
    self.unregisterDraggedTypes()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    // Unregister drag types so file drops pass through to SwiftUI
    self.unregisterDraggedTypes()
  }

  // Override drag methods to prevent file handling
  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    // Don't handle drags - let them pass through to SwiftUI
    return []
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    // Don't handle drags - let SwiftUI handle them
    return false
  }

  public var isAtBottom: Bool {
    guard let docView = documentView else { return true }
    let visibleHeight = contentView.bounds.height
    let contentHeight = docView.frame.height
    let scrollY = contentView.bounds.origin.y

    let tolerance = 100.0
    let docBottom = (scrollY + visibleHeight)
    let scrollBottomZone = contentHeight - tolerance
    let result = (docBottom >= scrollBottomZone)
    return result
  }
}

// MARK: - SwiftUI Wrapper

struct ProvenanceTrackingTextEditor: NSViewRepresentable {
  // @Binding var attributedText: NSAttributedString
  @Binding var selectedLineIds: [UInt64]
  var fontSize: CGFloat
  var onFileDrag: ((NSDraggingInfo) -> Bool)?
  var textViewRef: Binding<ProvenanceTextView?>?
  var textStorageRef: Binding<ProvenanceTrackingTextStorage?>?
  var onTextViewReady: ((ProvenanceTextView) -> Void)?
  var onAttributedTextChange: ((NSAttributedString) -> Void)?

  class Coordinator {
    var attributedText: NSAttributedString = NSAttributedString()
    var textView: ProvenanceTextView?
    var textStorage: ProvenanceTrackingTextStorage?
  }

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeNSView(context: Context) -> NSScrollView {
    let scrollView = AutoScrollView()

    // Create custom text storage
    let textStorage = ProvenanceTrackingTextStorage()
    let textView = ProvenanceTextView(frame: .zero, textStorage: textStorage)

    textView.isRichText = true
    textView.allowsUndo = true
    textView.isEditable = true
    textView.isSelectable = true
    textView.typingAttributes = [
      .font: NSFont.systemFont(ofSize: fontSize)
    ]
    textView.usesInspectorBar = true
    // Apply font size as default
    textView.font = NSFont.systemFont(ofSize: fontSize)

    scrollView.documentView = textView
    scrollView.hasVerticalScroller = true
    scrollView.hasHorizontalScroller = false
    scrollView.autohidesScrollers = true
    scrollView.autoresizingMask = [.width, .height]

    textView.autoresizingMask = [.width]
    textView.isVerticallyResizable = true
    textView.isHorizontallyResizable = false

    textView.onSelectionChange = { newLineIds in
      DispatchQueue.main.async {
        self.selectedLineIds = newLineIds
      }
    }
    textView.onFileDrag = onFileDrag
    textView.onAttributedTextChange = onAttributedTextChange

    // Store reference in coordinator
    context.coordinator.textView = textView
    context.coordinator.textStorage = textStorage

    // // Set binding asynchronously to avoid "modifying state during view update" warning
    DispatchQueue.main.async {
      textViewRef?.wrappedValue = textView
      textStorageRef?.wrappedValue = textStorage
      onTextViewReady?(textView)
    }

    return scrollView
  }

  func updateNSView(_ scrollView: NSScrollView, context: Context) {
    guard let textView = context.coordinator.textView else { return }
  }
}

func printAttributedString(attributedString: NSAttributedString) {
  attributedString.enumerateAttribute(
    .transcriptLineMetadata, in: NSRange(location: 0, length: attributedString.length), options: []
  ) { value, range, _ in
    let text = (attributedString.string as NSString).substring(with: range)
    print(
      "printAttributedString: value: \(String(describing: value)), range: \(range), text: \(text)")
  }
}

func extractSegments(from attributedString: NSAttributedString) -> [TranscriptTextSegment] {
  var segments: [TranscriptTextSegment] = []
  let fullRange = NSRange(location: 0, length: attributedString.length)

  attributedString.enumerateAttribute(.transcriptLineMetadata, in: fullRange, options: []) {
    value, range, _ in
    let text = (attributedString.string as NSString).substring(with: range)

    if let data = value as? Data, let metadata = decodeMetadata(data) {
      segments.append(TranscriptTextSegment(text: text, metadata: metadata))
    }
  }

  let result = mergeAdjacentSegments(segments)
  return result
}

func mergeAdjacentSegments(_ segments: [TranscriptTextSegment]) -> [TranscriptTextSegment] {
  guard !segments.isEmpty else { return [] }

  var result: [TranscriptTextSegment] = []
  var current = segments[0]

  for segment in segments.dropFirst() {
    // Merge if metadata is identical (same times, same edited status)
    if current.metadata.lineId == segment.metadata.lineId {
      current = TranscriptTextSegment(
        text: current.text + segment.text,
        metadata: current.metadata
      )
    } else {
      result.append(current)
      current = segment
    }
  }
  result.append(current)

  return result
}
