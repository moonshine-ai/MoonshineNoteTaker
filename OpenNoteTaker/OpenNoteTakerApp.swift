/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
The entry point into this app.
*/
import SwiftUI

@main
struct OpenNoteTakerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 100, minHeight: 100)
                .background(.white)
        }
        .defaultSize(width: 960, height: 724)
    }
}
