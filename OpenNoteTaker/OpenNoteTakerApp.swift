/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The entry point into this app.
*/
import SwiftUI
import AppKit

@main
struct OpenNoteTakerApp: App {
    init() {
        // Ensure a new document window is created on app launch if no documents are restored
        // Observe when the app finishes launching to check if we need to create a new document
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            // Use a small delay to allow document restoration to complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let documentController = NSDocumentController.shared
                // Only create a new document if no documents are currently open
                // This handles the case where no documents were restored from a previous session
                if documentController.documents.isEmpty {
                    documentController.newDocument(nil)
                }
            }
        }
    }
    
    var body: some Scene {
        DocumentGroup(newDocument: {
            // The newDocument closure may be called from a background thread,
            // but TranscriptDocument is @MainActor, so we need to ensure
            // we're on the main actor when creating it.
            if Thread.isMainThread {
                var transcriptDocument: TranscriptDocument = MainActor.assumeIsolated {
                    return TranscriptDocument()
                }
                return transcriptDocument
            } else {
                // Dispatch to main thread synchronously to create the document
                var document: TranscriptDocument?
                DispatchQueue.main.sync {
                    document = TranscriptDocument()
                }
                return document!
            }
        }) { configuration in
            ContentView(document: configuration.document)
                .frame(minWidth: 100, minHeight: 100)
                .background(.white)
        }
        .defaultSize(width: 960, height: 724)
    }
}
