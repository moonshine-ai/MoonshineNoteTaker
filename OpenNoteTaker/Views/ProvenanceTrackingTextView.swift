import SwiftUI
import AppKit

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
    static let transcriptLineMetadata = NSAttributedString.Key("ai.moonshine.opennotetaker.transcriptLineMetadata")
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

// MARK: - NSTextView Subclass

class ProvenanceTrackingTextView: NSTextView {
    
    var onTextChange: ((NSAttributedString) -> Void)?
    
    // Track the range being modified and its original metadata
    private var pendingEditRange: NSRange?
    private var pendingEditMetadata: TranscriptLineMetadata?
    
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else {
            return false
        }
        
        // Capture the metadata at the edit location BEFORE the edit happens
        pendingEditRange = affectedCharRange
        pendingEditMetadata = metadataAtOrNear(affectedCharRange)
        
        return true
    }
    
    /// Get metadata at the given range, or from adjacent text if the range is empty (cursor position)
    private func metadataAtOrNear(_ range: NSRange) -> TranscriptLineMetadata? {
        guard let textStorage = textStorage, textStorage.length > 0 else { return nil }
        
        // If we have a selection with content, use its start
        if range.length > 0 {
            let attrs = textStorage.attributes(at: range.location, effectiveRange: nil)
            return getMetadata(from: attrs)
        }
        
        // For insertion point (zero-length range), check character before cursor first,
        // then character after if at the start
        if range.location > 0 {
            let attrs = textStorage.attributes(at: range.location - 1, effectiveRange: nil)
            if let meta = getMetadata(from: attrs) {
                return meta
            }
        }
        
        if range.location < textStorage.length {
            let attrs = textStorage.attributes(at: range.location, effectiveRange: nil)
            if let meta = getMetadata(from: attrs) {
                return meta
            }
        }
        
        return nil
    }
    
    override func didChangeText() {
        super.didChangeText()
        
        // Mark any newly inserted text with the captured metadata (flagged as user-edited)
        if let metadata = pendingEditMetadata {
            markRecentInsertionAsUserEdited(with: metadata)
        }
        
        pendingEditRange = nil
        pendingEditMetadata = nil
        
        onTextChange?(attributedString())
    }
    
    private func markRecentInsertionAsUserEdited(with sourceMetadata: TranscriptLineMetadata) {
        guard let textStorage = textStorage else { return }
        
        // Walk through and find any ranges that inherited metadata but should be marked as edited
        // This handles the case where the text system copied attributes during insertion
        
        let fullRange = NSRange(location: 0, length: textStorage.length)
        
        // Simpler approach: mark everything with the source metadata's times as user-edited
        // if it wasn't already. This works because newly inserted text inherits attributes.
        ensureUserEditedFlag(in: fullRange, for: sourceMetadata)
    }
    
    private func ensureUserEditedFlag(in range: NSRange, for sourceMetadata: TranscriptLineMetadata) {
        guard let textStorage = textStorage else { return }
        
        var rangesToUpdate: [(NSRange, TranscriptLineMetadata)] = []
        
        textStorage.enumerateAttribute(.transcriptLineMetadata, in: range, options: []) { value, attrRange, _ in
            guard let data = value as? Data, var meta = decodeMetadata(data) else { return }
            
            // If this has the same time range as our source but isn't marked edited, mark it
            if meta.lineId == sourceMetadata.lineId &&
               !meta.userEdited {
                meta.userEdited = true
                rangesToUpdate.append((attrRange, meta))
            }
        }
        
        // Apply updates outside of enumeration
        for (attrRange, updatedMeta) in rangesToUpdate {
            if let encoded = encodeMetadata(updatedMeta) {
                textStorage.addAttribute(.transcriptLineMetadata, value: encoded, range: attrRange)
            }
        }
    }
}

// More robust approach: use a custom text storage

class ProvenanceTrackingTextStorage: NSTextStorage {
    private let backingStore = NSMutableAttributedString()
    private var isEditing = false
    private var editedRangeStart: Int = 0
    private var editedRangeEnd: Int = 0
    
    override var string: String {
        backingStore.string
    }
    
    override func attributes(at location: Int, effectiveRange range: NSRangePointer?) -> [NSAttributedString.Key: Any] {
        let attrs = backingStore.attributes(at: location, effectiveRange: range)
        // Only log occasionally to avoid spam - log when we're checking a recently edited location
        // This is called very frequently, so we'll be selective
        return attrs
    }
    
    override func replaceCharacters(in range: NSRange, with str: String) {
        let delta = str.utf16.count - range.length
        
        // Get metadata to apply to new text (from the position being edited)
        let metadataForInsertion = getMetadataForInsertion(at: range)
        
        beginEditing()
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
        
        endEditing()
    }
    
    override func setAttributes(_ attrs: [NSAttributedString.Key: Any]?, range: NSRange) {
        // Preserve existing custom metadata attribute when NSTextView applies default formatting
        // Only preserve if attrs is provided (not nil) but doesn't include metadata
        // If attrs is nil, that's an explicit clear, so we respect that
        var mergedAttrs: [NSAttributedString.Key: Any]? = attrs
        
        if let attrs = attrs {
            // attrs is provided - check if we need to preserve existing metadata
            if range.location < backingStore.length {
                let checkRange = NSRange(location: range.location, length: min(range.length, backingStore.length - range.location))
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
        
        beginEditing()
        // Apply merged attributes that include preserved metadata (or nil if clearing)
        backingStore.setAttributes(mergedAttrs, range: range)
                
        edited(.editedAttributes, range: range, changeInLength: 0)
        endEditing()
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
}

// MARK: - Text View with Custom Storage

class ProvenanceTextView: NSTextView {
    var onTextChange: ((NSAttributedString) -> Void)?
    
    convenience init(frame: NSRect, textStorage: ProvenanceTrackingTextStorage) {
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        
        let textContainer = NSTextContainer(containerSize: NSSize(width: frame.width, height: .greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        
        self.init(frame: frame, textContainer: textContainer)
        
        // Set up to expand vertically
        self.isVerticallyResizable = true
        self.isHorizontallyResizable = false
        self.textContainerInset = NSSize(width: 0, height: 0)
    }
    
    override func didChangeText() {
        super.didChangeText()
        // Create a copy so SwiftUI sees it as a new object
        let attrString = attributedString()
                
        let copy = NSMutableAttributedString(attributedString: attrString)
        onTextChange?(copy)
    }
}

// MARK: - SwiftUI Wrapper

struct ProvenanceTrackingTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var fontSize: CGFloat
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        
        // Create custom text storage
        let textStorage = ProvenanceTrackingTextStorage()
        if attributedText.length > 0 {
            textStorage.setAttributedString(attributedText)
            // Apply font size to initial text
            let font = NSFont.systemFont(ofSize: fontSize)
            let fullRange = NSRange(location: 0, length: textStorage.length)
            textStorage.addAttribute(.font, value: font, range: fullRange)
        }
        
        let textView = ProvenanceTextView(frame: .zero, textStorage: textStorage)
        
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        
        // Apply font size as default
        textView.font = NSFont.systemFont(ofSize: fontSize)
        
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        
        textView.onTextChange = { newAttrString in
            printAttributedString(attributedString: newAttrString)
            DispatchQueue.main.async {
                self.attributedText = newAttrString
            }
        }
        
        return scrollView
    }
    
    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? ProvenanceTextView else { return }
        
        // Update font size if it changed - apply to all text
        if let currentFont = textView.font, currentFont.pointSize != fontSize {
            textView.font = NSFont.systemFont(ofSize: fontSize)
            // Apply font size to all existing text
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let font = NSFont.systemFont(ofSize: fontSize)
                let fullRange = NSRange(location: 0, length: textStorage.length)
                textStorage.addAttribute(.font, value: font, range: fullRange)
            }
        }
        
        let textViewAttrString = textView.attributedString()
        let areEqual = textViewAttrString == attributedText
        
        if !areEqual {            
            let selectedRange = textView.selectedRange()
            textView.textStorage?.setAttributedString(attributedText)
            // Apply font size to the newly set text
            if let textStorage = textView.textStorage, textStorage.length > 0 {
                let font = NSFont.systemFont(ofSize: fontSize)
                let fullRange = NSRange(location: 0, length: textStorage.length)
                textStorage.addAttribute(.font, value: font, range: fullRange)
            }
            if selectedRange.location <= attributedText.length {
                textView.setSelectedRange(selectedRange)
            }
        }
    }
}

// MARK: - Helper Functions

func makeAttributedString(from segments: [TranscriptTextSegment]) -> NSAttributedString {
    let result = NSMutableAttributedString()
    for segment in segments {
        guard let encoded = encodeMetadata(segment.metadata) else { continue }
        let attrs: [NSAttributedString.Key: Any] = [.transcriptLineMetadata: encoded]
        let segmentStr = NSAttributedString(string: segment.text, attributes: attrs)
        result.append(segmentStr)
    }
    return result
}

func printAttributedString(attributedString: NSAttributedString) {
    attributedString.enumerateAttribute(.transcriptLineMetadata, in: NSRange(location: 0, length: attributedString.length), options: []) { value, range, _ in
        let text = (attributedString.string as NSString).substring(with: range)
        print("printAttributedString: value: \(String(describing: value)), range: \(range), text: \(text)")
    }
}

func extractSegments(from attributedString: NSAttributedString) -> [TranscriptTextSegment] {
    var segments: [TranscriptTextSegment] = []
    let fullRange = NSRange(location: 0, length: attributedString.length)
    
    attributedString.enumerateAttribute(.transcriptLineMetadata, in: fullRange, options: []) { value, range, _ in
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
