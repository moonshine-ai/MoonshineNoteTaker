/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
An object that captures a stream of captured sample buffers containing screen and audio content.
*/
import Foundation
import AVFAudio
import ScreenCaptureKit
import OSLog
import Combine
import SwiftUI

/// A structure that contains the video data to render.
struct CapturedFrame: @unchecked Sendable {
    static var invalid: CapturedFrame {
        CapturedFrame(surface: nil, contentRect: .zero, contentScale: 0, scaleFactor: 0)
    }

    let surface: IOSurface?
    let contentRect: CGRect
    let contentScale: CGFloat
    let scaleFactor: CGFloat
    var size: CGSize { contentRect.size }
}

/// An object that wraps an instance of `SCStream`, and returns its results as an `AsyncThrowingStream`.
class CaptureEngine: NSObject, @unchecked Sendable {
    
    private let logger = Logger()

    private(set) var stream: SCStream?
    private var streamOutput: CaptureEngineStreamOutput?
    // private let videoSampleBufferQueue = DispatchQueue(label: "com.example.apple-samplecode.VideoSampleBufferQueue")
    private let audioSampleBufferQueue = DispatchQueue(label: "ai.moonshine.notetaker.AudioSampleBufferQueue")
    private let micSampleBufferQueue = DispatchQueue(label: "ai.moonshine.notetaker.MicSampleBufferQueue")
        
    // Manages audio transcription using Moonshine Voice.
    let audioTranscriber: AudioTranscriber = AudioTranscriber()
    
    /// Set the transcript document for the audio transcriber.
    /// - Parameter document: The transcript document to update
    func setTranscriptDocument(_ document: TranscriptDocument) {
        audioTranscriber.transcriptDocument = document
    }
    
    // Store the the startCapture continuation, so that you can cancel it when you call stopCapture().
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?
    
    func startCapture(configuration: SCStreamConfiguration, filter: SCContentFilter) -> AsyncThrowingStream<CapturedFrame, Error> {
        AsyncThrowingStream<CapturedFrame, Error> { continuation in
            // The stream output object. Avoid reassigning it to a new object every time startCapture is called.
            let streamOutput = CaptureEngineStreamOutput(continuation: continuation)
            self.streamOutput = streamOutput
            streamOutput.capturedFrameHandler = { continuation.yield($0) }
            streamOutput.audioHandler = { buffer, audioType in
                if audioType != SCStreamOutputType.microphone {
                    try? self.audioTranscriber.addAudio(buffer, audioType: audioType)
                }
            }

            do {
                stream = SCStream(filter: filter, configuration: configuration, delegate: streamOutput)
                
                // Add stream outputs. Screen output is added but frames are discarded (video disabled).
                // try stream?.addStreamOutput(streamOutput, type: .screen, sampleHandlerQueue: videoSampleBufferQueue)
                try stream?.addStreamOutput(streamOutput, type: .audio, sampleHandlerQueue: audioSampleBufferQueue)
//                try stream?.addStreamOutput(streamOutput, type: .microphone, sampleHandlerQueue: micSampleBufferQueue)
                stream?.startCapture()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }
    
    func stopCapture() async {
        do {
            try await stream?.stopCapture()
            continuation?.finish()
        } catch {
            continuation?.finish(throwing: error)
        }
        try? audioTranscriber.stop()
    }
    
    func update(configuration: SCStreamConfiguration, filter: SCContentFilter) async {
        do {
            try await stream?.updateConfiguration(configuration)
            try await stream?.updateContentFilter(filter)
        } catch {
            logger.error("Failed to update the stream session: \(String(describing: error))")
        }
    }
    
    func addRecordOutputToStream(_ recordingOutput: SCRecordingOutput) async throws {
        try self.stream?.addRecordingOutput(recordingOutput)
    }
    
    func stopRecordingOutputForStream(_ recordingOutput: SCRecordingOutput) throws {
        try self.stream?.removeRecordingOutput(recordingOutput)
    }
    
    /// Initialize the audio transcriber with a model path.
    /// - Parameter modelPath: Path to the directory containing model files
    func initializeTranscriber(modelPath: String) throws {
        try audioTranscriber.initialize(modelPath: modelPath)
    }
    
    /// Start audio transcription.
    func startTranscription() throws {
        try audioTranscriber.start()
    }
    
    /// Stop audio transcription.
    func stopTranscription() throws {
        try audioTranscriber.stop()
    }
}

/// A class that handles output from an SCStream, and handles stream errors.
private class CaptureEngineStreamOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    
    var audioHandler: ((AVAudioPCMBuffer, SCStreamOutputType) -> Void)?
    var capturedFrameHandler: ((CapturedFrame) -> Void)?
    
    // Store the  startCapture continuation, so you can cancel it if an error occurs.
    private var continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?
    
    init(continuation: AsyncThrowingStream<CapturedFrame, Error>.Continuation?) {
        self.continuation = continuation
    }
    
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        // Return early if the sample buffer is invalid.
        guard sampleBuffer.isValid else { return }
        
        handleAudio(for: sampleBuffer, audioType: outputType)
    }
        
    private func handleAudio(for buffer: CMSampleBuffer, audioType: SCStreamOutputType) -> Void? {
        // Create an AVAudioPCMBuffer from an audio sample buffer.
        try? buffer.withAudioBufferList { audioBufferList, blockBuffer in
            guard let description = buffer.formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: description.mSampleRate, channels: description.mChannelsPerFrame),
                  let samples = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
            else { return }
            
            self.audioHandler!(samples, audioType)
        }
    }
    
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("Stream stopped with error: \(type(of: error)) \(error.localizedDescription)")
        continuation?.finish(throwing: error)
    }
}
