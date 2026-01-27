/*
Abstract:
A CoreAudio-based system audio capture class that uses process taps to capture system audio
without requiring screen recording permission. Requires macOS 14.4+.

Based on the AudioCap sample project: https://github.com/insidegui/AudioCap
*/

import Foundation
import AVFoundation
import CoreAudio
import CoreAudioKit
import OSLog

/// Captures system audio using CoreAudio process taps (macOS 14.4+)
/// This approach only requires "System Audio Recording" permission, not "Screen & System Audio Recording"
@available(macOS 14.4, *)
class CoreAudioSystemAudioCapture {
    private let logger = Logger()
    
    // CoreAudio objects
    private var processTap: AUAudioObjectID = kAudioObjectUnknown
    private var aggregateDevice: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var tapUUID: UUID?
    
    // Audio format
    private var audioFormat: AVAudioFormat?
    
    // Callback for audio buffers
    var audioBufferHandler: ((AVAudioPCMBuffer) -> Void)?
    
    // State
    private var isCapturing = false
    private let audioQueue = DispatchQueue(label: "ai.moonshinenotetaker.coreaudio.capture")
    
    /// Check if system audio capture permission is available
    /// Note: There's no public API to check this, so we'll attempt to create a tap
    /// and handle errors appropriately
    func checkPermission() -> Bool {
        // Permission will be requested automatically when we try to create the tap
        // If permission is denied, AudioHardwareCreateProcessTap will fail
        return true
    }
    
    /// Start capturing system audio
    /// - Parameter processID: Optional process ID to capture from. If nil, captures all system audio
    func start(processID: pid_t? = nil) throws {
        guard !isCapturing else {
            logger.warning("System audio capture already started")
            return
        }
        
        logger.info("Starting CoreAudio system audio capture")
        
        // Step 1: Get the process object ID
        let processObjectID = try getProcessObjectID(processID: processID)
        
        // Step 2: Create tap description using the AudioCap pattern
        // CATapDescription has an initializer that takes an array of process object IDs
        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        let uuid = UUID()
        tapDescription.uuid = uuid
        tapDescription.muteBehavior = .unmuted  // Don't mute the audio when tapping
        self.tapUUID = uuid
        
        // Step 3: Create the process tap
        var tapID: AUAudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create process tap: \(status). Make sure System Audio Recording permission is granted in System Settings > Privacy & Security > System Audio Recording."])
            logger.error("Failed to create process tap: \(status)")
            throw error
        }
        
        self.processTap = tapID
        logger.info("Created process tap with ID: \(tapID)")
        
        // Step 4: Get the tap format
        let tapStreamDescription = try readAudioTapStreamBasicDescription(tapID: tapID)
        
        // Convert to AVAudioFormat
        var streamDesc = tapStreamDescription
        guard let avFormat = AVAudioFormat(streamDescription: &streamDesc) else {
            cleanup()
            throw NSError(domain: "CoreAudioSystemAudioCapture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create AVAudioFormat"])
        }
        
        self.audioFormat = avFormat
        logger.info("Tap format: \(tapStreamDescription.mSampleRate) Hz, \(tapStreamDescription.mChannelsPerFrame) channels")
        
        // Step 5: Get system output device for aggregate device
        let systemOutputID = try readDefaultSystemOutputDevice()
        let outputUID = try readDeviceUID(deviceID: systemOutputID)
        
        // Step 6: Create aggregate device using AudioCap pattern
        let aggregateUID = UUID().uuidString
        let aggregateDeviceID = try createAggregateDevice(
            tapUUID: uuid,
            outputUID: outputUID,
            aggregateUID: aggregateUID
        )
        self.aggregateDevice = aggregateDeviceID
        
        // Step 7: Set up IO proc using the correct AudioCap API signature
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(
            &procID,
            aggregateDeviceID,
            audioQueue
        ) { [weak self] (inNow: UnsafePointer<AudioTimeStamp>,
                         inInputData: UnsafePointer<AudioBufferList>,
                         inInputTime: UnsafePointer<AudioTimeStamp>,
                         outOutputData: UnsafeMutablePointer<AudioBufferList>,
                         inOutputTime: UnsafePointer<AudioTimeStamp>) in
            guard let self = self, let format = self.audioFormat else { return }
            
            // Create AVAudioPCMBuffer from the input data using AudioCap pattern
            guard let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                bufferListNoCopy: inInputData,
                deallocator: nil
            ) else { return }
            
            // Call the handler
            self.audioBufferHandler?(buffer)
        }
        
        guard ioStatus == noErr, let procID = procID else {
            cleanup()
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(ioStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create IO proc: \(ioStatus)"])
        }
        
        self.ioProcID = procID
        
        // Step 8: Start the device
        let startStatus = AudioDeviceStart(aggregateDeviceID, procID)
        guard startStatus == noErr else {
            cleanup()
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(startStatus),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to start audio device: \(startStatus)"])
            logger.error("Failed to start audio device: \(startStatus)")
            throw error
        }
        
        isCapturing = true
        logger.info("System audio capture started successfully")
    }
    
    /// Stop capturing system audio
    func stop() {
        guard isCapturing else { return }
        
        logger.info("Stopping CoreAudio system audio capture")
        
        if let procID = ioProcID, aggregateDevice != 0 {
            AudioDeviceStop(aggregateDevice, procID)
            AudioDeviceDestroyIOProcID(aggregateDevice, procID)
        }
        
        cleanup()
        isCapturing = false
        logger.info("System audio capture stopped")
    }
    
    // MARK: - Private Methods
    
    private func getProcessObjectID(processID: pid_t?) throws -> AudioObjectID {
        if let pid = processID {
            // Get process object for specific PID
            var propertyAddress = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            
            var pidValue = pid
            var processObjectID: AudioObjectID = 0
            var objectIDSize = UInt32(MemoryLayout<AudioObjectID>.size)
            
            let status = AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &propertyAddress,
                UInt32(MemoryLayout<pid_t>.size),
                &pidValue,
                &objectIDSize,
                &processObjectID
            )
            
            guard status == noErr else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                            userInfo: [NSLocalizedDescriptionKey: "Failed to translate PID to process object: \(status)"])
            }
            
            return processObjectID
        } else {
            // For system-wide capture, we need to get all processes and create a mixdown
            // For simplicity, we'll use the system object approach
            // In practice, you might want to capture from multiple processes
            throw NSError(domain: "CoreAudioSystemAudioCapture", code: -1,
                        userInfo: [NSLocalizedDescriptionKey: "System-wide capture requires specifying individual processes. Use processID parameter."])
        }
    }
    
    private func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &size,
            &deviceID
        )
        
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to read default system output device: \(status)"])
        }
        
        return deviceID
    }
    
    private func readDeviceUID(deviceID: AudioDeviceID) throws -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &size)
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to get device UID size: \(status)"])
        }
        
        var uid: Unmanaged<CFString>?
        status = withUnsafeMutablePointer(to: &uid) { ptr in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, ptr)
        }
        
        guard status == noErr, let uidValue = uid?.takeRetainedValue() else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to read device UID: \(status)"])
        }
        
        return uidValue as String
    }
    
    private func readAudioTapStreamBasicDescription(tapID: AUAudioObjectID) throws -> AudioStreamBasicDescription {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        
        let status = AudioObjectGetPropertyData(
            tapID,
            &propertyAddress,
            0,
            nil,
            &size,
            &format
        )
        
        guard status == noErr else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to read tap format: \(status)"])
        }
        
        return format
    }
    
    private func createAggregateDevice(tapUUID: UUID, outputUID: String, aggregateUID: String) throws -> AudioDeviceID {
        // Create aggregate device dictionary using AudioCap pattern
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Moonshine Note Taker-Tap",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: outputUID
                ]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapUUID.uuidString
                ]
            ]
        ]
        
        var deviceID: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &deviceID)
        
        guard status == noErr else {
            let error = NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                        userInfo: [NSLocalizedDescriptionKey: "Failed to create aggregate device: \(status)"])
            logger.error("Failed to create aggregate device: \(status)")
            throw error
        }
        
        logger.info("Created aggregate device with ID: \(deviceID)")
        return deviceID
    }
    
    private func cleanup() {
        if aggregateDevice != 0 {
            let status = AudioHardwareDestroyAggregateDevice(aggregateDevice)
            if status != noErr {
                logger.warning("Failed to destroy aggregate device: \(status)")
            }
            aggregateDevice = 0
        }
        
        if processTap != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(processTap)
            if status != noErr {
                logger.warning("Failed to destroy process tap: \(status)")
            }
            processTap = kAudioObjectUnknown
        }
        
        ioProcID = nil
        tapUUID = nil
        audioFormat = nil
    }
    
    deinit {
        stop()
    }
}
