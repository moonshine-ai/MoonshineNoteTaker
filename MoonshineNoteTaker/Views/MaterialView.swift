/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A wrapper view around NSVisualEffectView.
*/

import SwiftUI

struct MaterialView: NSViewRepresentable {
    
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        return view
    }
    
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
