import SwiftUI
import AppKit

// MARK: - FocusedValue for Export Action
struct ImportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var importAction: (() -> Void)? {
        get { self[ImportActionKey.self] }
        set { self[ImportActionKey.self] = newValue }
    }
}

struct ExportActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportAction: (() -> Void)? {
        get { self[ExportActionKey.self] }
        set { self[ExportActionKey.self] = newValue }
    }
}

@main
struct OpenNoteTakerApp: App {
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontFamily") private var fontFamily: String = "System"

    init() {
        // Force a new document if none are restored
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }
    var body: some Scene {
        DocumentGroup(newDocument: {
            return TranscriptDocument()
        }) { configuration in
            ContentView(document: configuration.document)
                .frame(minWidth: 100, minHeight: 100)
                .background(.white)
        }
        .defaultSize(width: 480, height: 724)
        .commands {
            CommandGroup(replacing: .importExport) {
                ImportCommand()
                ExportCommand()
            }
            TextFormattingCommands()
        }
    }
}

// MARK: - Export Command

struct ImportCommand: View {
    @FocusedValue(\.importAction) var importAction
    
    var body: some View {
        Button("Import...") {
            importAction?()
        }
        .keyboardShortcut("i", modifiers: [.command])
        .disabled(importAction == nil)
    }
}

struct ExportCommand: View {
    @FocusedValue(\.exportAction) var exportAction
    
    var body: some View {
        Button("Export...") {
            exportAction?()
        }
        .keyboardShortcut("e", modifiers: [.command])
        .disabled(exportAction == nil)
    }
}