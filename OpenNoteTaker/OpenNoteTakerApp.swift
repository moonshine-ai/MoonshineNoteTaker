/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
The entry point into this app.
*/
import SwiftUI
import AppKit

// AppDelegate to handle automatic document creation on launch
class AppDelegate: NSObject, NSApplicationDelegate {
    // Return true to automatically open an untitled file when the app launches
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.async {
            if NSDocumentController.shared.documents.isEmpty {
                NSDocumentController.shared.newDocument(nil)
            }
        }
    }
}

@main
struct OpenNoteTakerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
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
        .defaultSize(width: 480, height: 724)
    }
}
