//
//  MicrophonePCMSampleVendor.swift
//  AIProxy
//
//  Created by Lou Zell
//
//  Modified by Pete Warden for Moonshine Note Taker, originally from AIProxy:
//  https://github.com/lzell/AIProxySwift/blob/lz/add-realtime-support/Sources/AIProxy/MicrophonePCMSampleVendor.swift
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// This is an AudioToolbox-based implementation that vends PCM16 microphone samples at a
/// sample rate that OpenAI's realtime models expect.
///
/// ## Requirements
///
/// - Assumes an `NSMicrophoneUsageDescription` description has been added to Target > Info
/// - Assumes that microphone permissions have already been granted
///
/// ## Usage
///
/// ```
///     let microphoneVendor = MicrophonePCMSampleVendor()
///     try microphoneVendor.start { sample in
///        // Do something with `sample`
///
///     }
///     // some time later...
///     microphoneVendor.stop()
/// ```
///
///
/// ## References:
///
/// See the section "Essential Characteristics of I/O Units" here:
/// https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitHostingGuide_iOS/AudioUnitHostingFundamentals/AudioUnitHostingFundamentals.html
///
/// See AudioUnit setup from these two obj-c projects:
/// https://developer.apple.com/library/archive/samplecode/aurioTouch/Introduction/Intro.html#//apple_ref/doc/uid/DTS40007770
/// https://developer.apple.com/library/archive/samplecode/AVCaptureToAudioUnitOSX/Introduction/Intro.html#//apple_ref/doc/uid/DTS40012879
///
/// Apple technical note for performing audio conversions *when the sample rate is different*
/// https://developer.apple.com/documentation/technotes/tn3136-avaudioconverter-performing-sample-rate-conversions
///
/// This is an important answer to eliminate pops when using an AVAudioConverter:
/// https://stackoverflow.com/questions/64553738/avaudioconverter-corrupts-data
///
/// Apple sample code (Do not use this): https://developer.apple.com/documentation/avfaudio/using-voice-processing
/// My apple forum question (Do not use this): https://developer.apple.com/forums/thread/771530
open class MicrophonePCMSampleVendor {

    private var audioUnit: AudioUnit?
    private var audioConverter: AVAudioConverter?
    private var continuation: AsyncStream<AVAudioPCMBuffer>.Continuation?
    private let voiceProcessingInputSampleRate: Double = 44100

    public init() {}

    /// Start capturing microphone audio.
    ///
    /// - Parameter deviceID: A specific `AudioDeviceID` to capture from, or `nil`
    ///   to use the current system default input device. Obtain device IDs from
    ///   `AudioDeviceManager.availableInputDevices`.
    public func start(deviceID: AudioDeviceID? = nil) throws -> AsyncStream<AVAudioPCMBuffer> {
        var desc = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )

        guard let component = AudioComponentFindNext(nil, &desc) else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not find an audio component with VoiceProcessingIO"
            )
        }

        AudioComponentInstanceNew(component, &audioUnit)
        guard let audioUnit = audioUnit else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not instantiate an audio component with VoiceProcessingIO"
            )
        }

        // ---------------------------------------------------------------
        // Set the input device BEFORE configuring formats and initializing.
        // This must happen early so the AU knows which hardware it's
        // talking to when we query/set stream formats.
        // ---------------------------------------------------------------
        #if os(macOS)
        if let deviceID = deviceID {
            var mutableDeviceID = deviceID
            let err = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &mutableDeviceID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            guard err == noErr else {
                throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                    "Could not set audio input device (ID: \(deviceID), error: \(err))"
                )
            }
        }
        #endif

        var otherAudioDuckingConfiguration = AUVoiceIOOtherAudioDuckingConfiguration(
            mEnableAdvancedDucking: false,
            mDuckingLevel: AUVoiceIOOtherAudioDuckingLevel.min
        )

        var err: OSStatus = AudioUnitSetProperty(audioUnit,
                                   kAUVoiceIOProperty_OtherAudioDuckingConfiguration /* kAudioUnitProperty_SetRenderCallback */,
                                   kAudioUnitScope_Global /* kAudioUnitScope_Input */,
                                   0,
                                   &otherAudioDuckingConfiguration,
                                   UInt32(MemoryLayout<AUVoiceIOOtherAudioDuckingConfiguration>.size))

        guard err == noErr else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not set the other audio ducking configuration on the voice processing audio unit"
            )
        }

        var one: UInt32 = 1
        err = AudioUnitSetProperty(audioUnit,
                                       kAudioOutputUnitProperty_EnableIO,
                                       kAudioUnitScope_Input,
                                       1,
                                       &one,
                                       UInt32(MemoryLayout.size(ofValue: one)))

        guard err == noErr else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not enable the input scope of the microphone bus"
            )
        }

        var zero: UInt32 = 0
        err = AudioUnitSetProperty(audioUnit,
                                   kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Output,
                                   0,
                                   &zero, // <-- This is not a mistake! If you leave this on, iOS spams the logs with: "from AU (address): auou/vpio/appl, render err: -1"
                                   UInt32(MemoryLayout.size(ofValue: one)))

        guard err == noErr else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not disable the output scope of the speaker bus"
            )
        }

        // Refer to the diagram in the "Essential Characteristics of I/O Units" section here:
        // https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitHostingGuide_iOS/AudioUnitHostingFundamentals/AudioUnitHostingFundamentals.html
        var hardwareASBD = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let _ = AudioUnitGetProperty(audioUnit,
                                          kAudioUnitProperty_StreamFormat,
                                          kAudioUnitScope_Input,
                                          1,
                                          &hardwareASBD,
                                          &size)

        var ioFormat = AudioStreamBasicDescription(
            mSampleRate: voiceProcessingInputSampleRate, // Sample rate (Hz) IMPORTANT, on macOS 44100 is the *only* sample rate that will work with the voice processing AU
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )

        err = AudioUnitSetProperty(audioUnit,
                                   kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output,
                                   1,
                                   &ioFormat,
                                   UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        )
        guard err == noErr else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not set ASBD on the output scope of the mic bus"
            )
        }

        var inputCallbackStruct = AURenderCallbackStruct(
            inputProc: audioRenderCallback,
            inputProcRefCon: Unmanaged.passUnretained(self).toOpaque()
        )
        err = AudioUnitSetProperty(audioUnit,
                                   kAudioOutputUnitProperty_SetInputCallback /* kAudioUnitProperty_SetRenderCallback */,
                                   kAudioUnitScope_Global /* kAudioUnitScope_Input */,
                                   1,
                                   &inputCallbackStruct,
                                   UInt32(MemoryLayout<AURenderCallbackStruct>.size))

        guard err == noErr else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not set the render callback on the voice processing audio unit"
            )
        }

        err = AudioUnitInitialize(audioUnit)
        guard err == noErr else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not initialize the audio unit"
            )
        }

        err = AudioOutputUnitStart(audioUnit)
        guard err == noErr else {
            throw MicrophonePCMSampleVendorError.couldNotConfigureAudioUnit(
                "Could not start the audio unit"
            )
        }

        return AsyncStream<AVAudioPCMBuffer> { [weak self] continuation in
            self?.continuation = continuation
        }
    }

    public func stop() {
        self.continuation?.finish()
        self.continuation = nil
        if let au = self.audioUnit {
            AudioOutputUnitStop(au)
            AudioUnitUninitialize(au)
            self.audioUnit = nil
        }
        self.audioConverter = nil
    }

    private var debugIndex: Int = 0

    fileprivate func didReceiveRenderCallback(
        _ ioActionFlags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ inTimeStamp: UnsafePointer<AudioTimeStamp>,
        _ inBusNumber: UInt32,
        _ inNumberFrames: UInt32
    ) {
        guard let audioUnit = audioUnit else {
            print("There is no audioUnit attached to the sample vendor. Render callback should not be called")
            return
        }
        var bufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: inNumberFrames * 2,
                mData: UnsafeMutableRawPointer.allocate(
                    byteCount: Int(inNumberFrames) * 2,
                    alignment: MemoryLayout<Int16>.alignment
                )
            )
        )

        let status = AudioUnitRender(audioUnit,
                                     ioActionFlags,
                                     inTimeStamp,
                                     inBusNumber,
                                     inNumberFrames,
                                     &bufferList)

        guard status == noErr else {
            print("Could not render voice processed audio data to bufferList")
            return
        }

        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: voiceProcessingInputSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            print("Could not create audio format inside render callback.")
            return
        }

        if let inPCMBuf = AVAudioPCMBuffer(pcmFormat: audioFormat, bufferListNoCopy: &bufferList),
          let outPCMBuf = self.convertPCM16BufferToExpectedSampleRate(inPCMBuf)  {
            self.continuation?.yield(outPCMBuf)
        }
    }

    private func convertPCM16BufferToExpectedSampleRate(_ pcm16Buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let audioFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24000.0,
            channels: 1,
            interleaved: false
        ) else {
            print("Could not create target audio format")
            return nil
        }

        if self.audioConverter == nil {
            self.audioConverter = AVAudioConverter(from: pcm16Buffer.format, to: audioFormat)
        }

        guard let converter = self.audioConverter else {
            print("There is no audio converter to use for PCM16 resampling")
            return nil
        }

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: audioFormat,
            frameCapacity: AVAudioFrameCount(audioFormat.sampleRate * 2.0)
        ) else {
            print("Could not create output buffer for PCM16 resampling")
            return nil
        }

        var error: NSError?
        var ptr: UInt32 = 0
        let targetFrameLength = pcm16Buffer.frameLength
        let _ = converter.convert(to: outputBuffer, error: &error) { numberOfFrames, outStatus in
            guard ptr < targetFrameLength,
                  let workingCopy = advancedPCM16Buffer_noCopy(pcm16Buffer, offset: ptr)
            else {
                outStatus.pointee = .noDataNow
                return nil
            }
            let amountToFill = min(numberOfFrames, targetFrameLength - ptr)
            outStatus.pointee = .haveData
            ptr += amountToFill
            workingCopy.frameLength = amountToFill
            return workingCopy
        }

        if let error = error {
            print("Error converting to expected sample rate: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer
    }
}

// Renamed to avoid collision if old file is still in the project
private func advancedPCM16Buffer_noCopy(_ originalBuffer: AVAudioPCMBuffer, offset: UInt32) -> AVAudioPCMBuffer? {
    let audioBufferList = originalBuffer.mutableAudioBufferList
    guard audioBufferList.pointee.mNumberBuffers == 1,
          audioBufferList.pointee.mBuffers.mNumberChannels == 1
    else {
        print("Broken programmer assumption. Audio conversion depends on single channel PCM16 as input")
        return nil
    }
    guard let audioBufferData = audioBufferList.pointee.mBuffers.mData else {
        print("Could not get audio buffer data from the original PCM16 buffer")
        return nil
    }
    audioBufferList.pointee.mBuffers.mData = audioBufferData.advanced(
        by: Int(offset) * MemoryLayout<UInt16>.size
    )
    return AVAudioPCMBuffer(
        pcmFormat: originalBuffer.format,
        bufferListNoCopy: audioBufferList
    )
}

private let audioRenderCallback: AURenderCallback = {
    inRefCon,
    ioActionFlags,
    inTimeStamp,
    inBusNumber,
    inNumberFrames,
    ioData in
    let microphonePCMSampleVendor = Unmanaged<MicrophonePCMSampleVendor>
        .fromOpaque(inRefCon)
        .takeUnretainedValue()
    microphonePCMSampleVendor.didReceiveRenderCallback(
        ioActionFlags,
        inTimeStamp,
        inBusNumber,
        inNumberFrames
    )
    return noErr
}
