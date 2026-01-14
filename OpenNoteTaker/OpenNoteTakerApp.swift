import SwiftUI
import AppKit

@main
struct OpenNoteTakerApp: App {
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
    }
}
