import SwiftUI
import AppKit

// MARK: - FocusedValue for Export Action
struct ImportAudioActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var importAudioAction: (() -> Void)? {
        get { self[ImportAudioActionKey.self] }
        set { self[ImportAudioActionKey.self] = newValue }
    }
}

struct ExportTextActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportTextAction: (() -> Void)? {
        get { self[ExportTextActionKey.self] }
        set { self[ExportTextActionKey.self] = newValue }
    }
}

struct ExportAudioActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportAudioAction: (() -> Void)? {
        get { self[ExportAudioActionKey.self] }
        set { self[ExportAudioActionKey.self] = newValue }
    }
}

struct ExportCaptionsActionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var exportCaptionsAction: (() -> Void)? {
        get { self[ExportCaptionsActionKey.self] }
        set { self[ExportCaptionsActionKey.self] = newValue }
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
                ImportAudioCommand()
                ExportTextCommand()
                ExportAudioCommand()
                ExportCaptionsCommand()
            }
            TextFormattingCommands()
        }
    }
}

// MARK: - Export Command

struct ImportAudioCommand: View {
    @FocusedValue(\.importAudioAction) var importAudioAction
    
    var body: some View {
        Button("Import Audio...") {
            importAudioAction?()
        }
        .keyboardShortcut("i", modifiers: [.command])
        .disabled(importAudioAction == nil)
    }
}

struct ExportTextCommand: View {
    @FocusedValue(\.exportTextAction) var exportTextAction
    
    var body: some View {
        Button("Export Text...") {
            exportTextAction?()
        }
        .keyboardShortcut("e", modifiers: [.command])
        .disabled(exportTextAction == nil)
    }
}

struct ExportAudioCommand: View {
    @FocusedValue(\.exportAudioAction) var exportAudioAction
    
    var body: some View {
        Button("Export Audio...") {
            exportAudioAction?()
        }
        .disabled(exportAudioAction == nil)
    }
}

struct ExportCaptionsCommand: View {
    @FocusedValue(\.exportCaptionsAction) var exportCaptionsAction
    
    var body: some View {
        Button("Export Captions...") {
            exportCaptionsAction?()
        }
        .disabled(exportCaptionsAction == nil)
    }
}
