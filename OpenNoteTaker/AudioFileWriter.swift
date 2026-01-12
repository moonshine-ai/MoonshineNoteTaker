/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A utility class for writing audio buffers to a WAV file for debugging.
*/

import Foundation
import AVFoundation
import OSLog

/// A class that writes audio buffers to a WAV file for debugging purposes.
class AudioFileWriter {
    private let logger = Logger()
    private var audioFile: AVAudioFile?
    private var outputURL: URL?
    private let queue = DispatchQueue(label: "com.opennote.audiofilewriter")
    private var isWriting = false
    
    /// Start writing audio to a WAV file.
    /// - Parameters:
    ///   - format: The audio format of the incoming buffers
    ///   - url: The file URL to write to
    /// - Returns: True if successfully started, false otherwise
    func startWriting(format: AVAudioFormat, to url: URL) -> Bool {
        queue.sync {
            guard !isWriting else {
                logger.warning("Audio file writer is already writing")
                return false
            }
            
            do {
                // Use the input format directly - WAV files support various PCM formats including float32
                // This ensures compatibility without format conversion
                let settings = format.settings
                
                print("settings: \(settings)")
                // Create the audio file
                audioFile = try AVAudioFile(forWriting: url, settings: settings)
                outputURL = url
                isWriting = true
                logger.info("Started writing system audio to WAV file: \(url.path)")
                return true
            } catch {
                logger.error("Failed to create audio file: \(error.localizedDescription)")
                return false
            }
        }
    }
    
    /// Write an audio buffer to the file.
    /// - Parameter buffer: The audio buffer to write
    func write(_ buffer: AVAudioPCMBuffer) {
        queue.async { [weak self] in
            guard let self = self, self.isWriting, let audioFile = self.audioFile else { return }
            
            do {
                // Write the buffer (format conversion is handled automatically by AVAudioFile)
                try audioFile.write(from: buffer)
            } catch {
                self.logger.error("Failed to write audio buffer: \(error.localizedDescription)")
            }
        }
    }
    
    /// Stop writing and close the file.
    func stopWriting() {
        queue.sync {
            guard isWriting else { return }
            
            audioFile = nil
            isWriting = false
            
            if let url = outputURL {
                logger.info("Stopped writing audio file: \(url.path)")
            }
            outputURL = nil
        }
    }
    
    /// Get the URL of the current output file.
    var currentOutputURL: URL? {
        queue.sync {
            return outputURL
        }
    }
}

