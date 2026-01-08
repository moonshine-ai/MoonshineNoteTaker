/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view that renders an audio level meter.
*/

import Foundation
import SwiftUI

struct AudioLevelsView: NSViewRepresentable {
    
    @StateObject var audioLevelsProvider: AudioLevelsProvider
    
    func makeNSView(context: Context) -> NSLevelIndicator {
        let levelIndicator = NSLevelIndicator(frame: .zero)
        levelIndicator.minValue = 0
        levelIndicator.maxValue = 10
        levelIndicator.warningValue = 6
        levelIndicator.criticalValue = 8
        levelIndicator.levelIndicatorStyle = .continuousCapacity
        levelIndicator.heightAnchor.constraint(equalToConstant: 5).isActive = true
        return levelIndicator
    }
    
    func updateNSView(_ levelMeter: NSLevelIndicator, context: Context) {
        levelMeter.floatValue = audioLevelsProvider.audioLevels.level * 10
    }
}
