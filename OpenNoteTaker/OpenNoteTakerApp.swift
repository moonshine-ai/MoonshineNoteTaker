import SwiftUI
import AppKit

extension Notification.Name {
    static let importFiles = Notification.Name("importFiles")
}

// MARK: - FocusedValue for Export Action

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
                Button("Import...") {
                    NotificationCenter.default.post(name: .importFiles, object: nil)
                }
                .keyboardShortcut("i", modifiers: .command)
                
                ExportCommand()
            }
            TextFormattingCommands()
        }
    }
}

// MARK: - Export Command

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