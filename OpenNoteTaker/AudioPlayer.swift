import Foundation
import AVFoundation

class AudioPlayer: ObservableObject {
    let engine: AVAudioEngine
    var transcriptDocument: TranscriptDocument
    var isPlaying: Bool = false

    init() {
        self.transcriptDocument = TranscriptDocument()
        
        engine = AVAudioEngine()

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        let sourceNode = AVAudioSourceNode(format: format) { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buffer = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            
            let (audio, reachedEnd) = self.transcriptDocument.getNextAudioData(length: frameCount)
            for i in 0..<audio.count {
                buffer[i] = audio[i]
            }
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func play() throws {
        isPlaying = true
        transcriptDocument.resetPlaybackOffset()
        try engine.start()
    }

    func stop() {
        isPlaying = false
        engine.stop()
    }
}
