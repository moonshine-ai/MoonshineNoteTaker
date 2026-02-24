//
//  AudioDeviceManager.swift
//  MoonshineNoteTaker
//
//  Enumerates macOS audio input devices and supports selecting a specific
//  device for use with VoiceProcessingIO audio units.
//

import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation
import SwiftUI

/// Represents an available audio input device on macOS.
public struct AudioInputDevice: Identifiable, Hashable {
    public let id: AudioDeviceID
    public let name: String
    public let uid: String
    public let inputChannelCount: Int

    /// Whether this is the current system default input device.
    public var isDefault: Bool = false
}

/// Manages enumeration, selection, and monitoring of macOS audio input devices.
///
/// ## Usage with SwiftUI
/// ```swift
/// @StateObject var deviceManager = AudioDeviceManager()
///
/// Picker("Microphone", selection: $deviceManager.selectedDeviceUID) {
///     Text("System Default").tag(String?.none)
///     ForEach(deviceManager.availableInputDevices) { device in
///         Text(device.name).tag(Optional(device.uid))
///     }
/// }
/// ```
///
/// ## Usage with MicrophonePCMSampleVendor
/// ```swift
/// let vendor = MicrophonePCMSampleVendor()
/// let stream = try vendor.start(deviceID: deviceManager.selectedDeviceID)
/// ```
public class AudioDeviceManager: ObservableObject {

    /// App-wide shared instance. Use this when you need the device manager from
    /// deep in the object graph (e.g. MicrophonePCMSampleVendor) without
    /// passing it through every constructor.
    public static let shared = AudioDeviceManager()

    /// All available input devices. Updated automatically when devices are
    /// added/removed (e.g. plugging in a USB microphone).
    @Published public private(set) var availableInputDevices: [AudioInputDevice] = []

    /// The persisted UID of the selected device. Use this for Picker bindings
    /// and for persistence. `nil` means "use the system default".
    @AppStorage("selectedAudioInputDeviceUID")
    public var selectedDeviceUID: String?

    /// Resolved `AudioDeviceID` for the current selection. Pass this to
    /// `MicrophonePCMSampleVendor.start(deviceID:)`. Returns `nil` when
    /// set to system default or if the saved device is no longer available.
    public var selectedDeviceID: AudioDeviceID? {
        guard let uid = selectedDeviceUID else { return nil }
        return availableInputDevices.first(where: { $0.uid == uid })?.id
    }

    /// Listener for hardware device changes (connect/disconnect).
    private var deviceListListenerBlock: AudioObjectPropertyListenerBlock?

    public init() {
        refreshDevices()
        installDeviceChangeListener()
    }

    deinit {
        removeDeviceChangeListener()
    }

    // MARK: - Device Enumeration

    /// Refreshes the list of available input devices from CoreAudio.
    public func refreshDevices() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize
        )
        guard status == noErr else {
            print("AudioDeviceManager: Could not get device list size: \(status)")
            return
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &dataSize,
            &deviceIDs
        )
        guard status == noErr else {
            print("AudioDeviceManager: Could not get device list: \(status)")
            return
        }

        let defaultInputID = getDefaultInputDeviceID()

        var devices: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            let inputChannels = getInputChannelCount(for: deviceID)
            guard inputChannels > 0 else { continue }  // Skip output-only devices

            // Skip aggregate and virtual devices (e.g. VPAU, CADefaultDeviceAggregate)
            // so the picker only shows physical mics.
            if isAggregateOrVirtual(deviceID) { continue }

            let name = getDeviceName(for: deviceID)
            let uid = getDeviceUID(for: deviceID)

            var device = AudioInputDevice(
                id: deviceID,
                name: name,
                uid: uid,
                inputChannelCount: inputChannels
            )
            device.isDefault = (deviceID == defaultInputID)
            devices.append(device)
        }

        // Sort: default device first, then alphabetical
        devices.sort { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        DispatchQueue.main.async {
            self.availableInputDevices = devices
        }
    }

    // MARK: - Device Change Monitoring

    private func installDeviceChangeListener() {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshDevices()
        }
        self.deviceListListenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    private func removeDeviceChangeListener() {
        guard let block = deviceListListenerBlock else { return }
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            DispatchQueue.main,
            block
        )
    }

    // MARK: - CoreAudio Property Helpers

    /// Excludes aggregate and virtual devices (e.g. VPAU, CADefaultDeviceAggregate)
    /// so only physical input devices appear in the picker.
    private func isAggregateOrVirtual(_ deviceID: AudioDeviceID) -> Bool {
        let transportType = getTransportType(for: deviceID)
        return transportType == kAudioDeviceTransportTypeAggregate
            || transportType == kAudioDeviceTransportTypeVirtual
    }

    private func getTransportType(for deviceID: AudioDeviceID) -> UInt32 {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transportType: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            deviceID,
            &propertyAddress,
            0, nil,
            &size,
            &transportType
        )
        return status == noErr ? transportType : 0
    }

    private func getDefaultInputDeviceID() -> AudioDeviceID {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0, nil,
            &size,
            &deviceID
        )
        return deviceID
    }

    private func getInputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return 0 }

        let bufferListPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { bufferListPointer.deallocate() }

        let result = AudioObjectGetPropertyData(
            deviceID, &propertyAddress, 0, nil, &dataSize, bufferListPointer
        )
        guard result == noErr else { return 0 }

        let ablPointer = UnsafeMutableAudioBufferListPointer(
            bufferListPointer.assumingMemoryBound(to: AudioBufferList.self)
        )
        var totalChannels: UInt32 = 0
        for i in 0..<ablPointer.count {
            totalChannels += ablPointer[i].mNumberChannels
        }
        return Int(totalChannels)
    }

    private func getDeviceName(for deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &name)
        return name as String
    }

    private func getDeviceUID(for deviceID: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &size, &uid)
        return uid as String
    }
}
