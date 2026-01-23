import SwiftUI
import AppKit

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
            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    fontSize = min(fontSize + 1.0, 72.0)
                }
                .keyboardShortcut("+", modifiers: .command)
                
                Button("Zoom Out") {
                    fontSize = max(fontSize - 1.0, 8.0)
                }
                .keyboardShortcut("-", modifiers: .command)
                
                Button("Actual Size") {
                    fontSize = 14.0
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }
    }
}
