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
        textContainer.heightTracksTextView = false
        layoutManager.addTextContainer(textContainer)

        self.init(frame: frame, textContainer: textContainer)

        self.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)

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

class AutoScrollView: NSScrollView {
    
    private var wasAtBottom = true
    private var observerSetup = false
    
    override func awakeFromNib() {
        super.awakeFromNib()
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if !observerSetup {
            setupObserver()
            observerSetup = true
        }
    }
    
    @MainActor
    private func setupObserver() {
        // Observe bounds changes on the content view (tracks scroll position)
        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(contentViewBoundsDidChange),
            name: NSView.boundsDidChangeNotification,
            object: contentView
        )
    }
    
    override var documentView: NSView? {
        didSet {
            guard let docView = documentView else { return }
            
            // Observe frame changes on the document view (tracks content size)
            docView.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(
                self,
                selector: #selector(documentViewFrameDidChange),
                name: NSView.frameDidChangeNotification,
                object: docView
            )
        }
    }
    
    private var isAtBottom: Bool {
        guard let docView = documentView else { return true }
        let visibleHeight = contentView.bounds.height
        let contentHeight = docView.frame.height
        let scrollY = contentView.bounds.origin.y
        
        // Allow a small tolerance (e.g., 1 point)
        return scrollY + visibleHeight >= contentHeight - 1
    }
    
    @objc private func contentViewBoundsDidChange(_ notification: Notification) {
        wasAtBottom = isAtBottom
    }
    
    @objc private func documentViewFrameDidChange(_ notification: Notification) {
        if wasAtBottom {
            scrollToBottom()
        }
    }
    
    func scrollToBottom() {
        guard let docView = documentView else { return }
        let maxY = max(0, docView.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: 0, y: maxY))
        reflectScrolledClipView(contentView)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - SwiftUI Wrapper

struct ProvenanceTrackingTextEditor: NSViewRepresentable {
    @Binding var attributedText: NSAttributedString
    var fontSize: CGFloat
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = AutoScrollView()
        
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
        scrollView.autoresizingMask = [.width, .height]
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        
        textView.onTextChange = { newAttrString in
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
