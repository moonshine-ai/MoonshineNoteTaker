import Foundation
import AVFoundation
import Combine

/// Events that can be posted from the audio thread to the UI
enum AudioPlayerEvent {
    case playbackReachedEnd
    case playbackError(Error)
    case playbackLineIdsUpdated(oldLineIds: [UInt64], newLineIds: [UInt64])
}

class AudioPlayer: ObservableObject {
    let engine: AVAudioEngine
    var transcriptDocument: TranscriptDocument
    @Published var isPlaying: Bool = false
    private var currentLineIds: [UInt64] = []
    
    /// Subject for posting events from the audio thread to the main thread
    /// Use this to communicate events that occur in the render callback
    private let eventSubject = PassthroughSubject<AudioPlayerEvent, Never>()
    
    /// Publisher for observing events from the UI
    var events: AnyPublisher<AudioPlayerEvent, Never> {
        eventSubject.eraseToAnyPublisher()
    }
    
    /// Flag to track if we've already sent the end event (to avoid duplicates)
    /// This is accessed from both the audio thread and main thread, so we use nonisolated(unsafe)
    private nonisolated(unsafe) var hasSentEndEvent: Bool = false

    init() {
        self.transcriptDocument = TranscriptDocument()
        
        engine = AVAudioEngine()

        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!

        let sourceNode = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            guard let self = self else { return noErr }
            
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let buffer = ablPointer[0].mData!.assumingMemoryBound(to: Float.self)
            
            let (audio, lineIds, reachedEnd) = self.transcriptDocument.getNextAudioData(length: frameCount)
            
            for i in 0..<audio.count {
                buffer[i] = audio[i]
            }

            if lineIds != self.currentLineIds {
                let eventSubject = self.eventSubject
                let oldLineIds = self.currentLineIds
                let newLineIds = lineIds
                DispatchQueue.main.async { [weak eventSubject, oldLineIds, newLineIds] in
                    eventSubject?.send(.playbackLineIdsUpdated(oldLineIds: oldLineIds, newLineIds: newLineIds))
                }
                self.currentLineIds = lineIds
            }
            
            // Post event to main thread if playback reached end (only once)
            // This is safe to call from the audio thread - DispatchQueue will handle the thread switch
            if reachedEnd && !self.hasSentEndEvent {
                self.hasSentEndEvent = true
                let eventSubject = self.eventSubject
                DispatchQueue.main.async { [weak eventSubject] in
                    eventSubject?.send(.playbackReachedEnd)
                }
            }
            
            return noErr
        }

        engine.attach(sourceNode)
        engine.connect(sourceNode, to: engine.mainMixerNode, format: format)
    }

    func play() throws {
        isPlaying = true
        hasSentEndEvent = false  // Reset flag when starting playback
        try engine.start()
    }

    func stop() {
        isPlaying = false
        engine.stop()
    }
}
