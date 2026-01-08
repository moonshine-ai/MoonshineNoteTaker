/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that holds an AVAudioPlayer that plays an AIFF file.
*/

import Foundation
import AVFoundation

class AudioPlayer: ObservableObject {
    
    let audioPlayer: AVAudioPlayer
    
    @Published var isPlaying = false
    
    init() {
        guard let url = Bundle.main.url(forResource: "Synth", withExtension: "aif") else {
            fatalError("Couldn't find Synth.aif in the app bundle.")
        }
        audioPlayer = try! AVAudioPlayer(contentsOf: url, fileTypeHint: AVFileType.aiff.rawValue)
        audioPlayer.numberOfLoops = -1 // Loop indefinitely.
        audioPlayer.prepareToPlay()
    }
    
    func play() {
        audioPlayer.play()
        isPlaying = true
    }
    
    func stop() {
        audioPlayer.stop()
        isPlaying = false
    }
}
