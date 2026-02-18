//
//  MicrophonePCMSampleVendorError.swift
//  AIProxy
//
//  Created by Lou Zell
//
//  Modified by Pete Warden for Moonshine Note Taker, originally from AIProxy:
//  https://github.com/lzell/AIProxySwift/blob/lz/add-realtime-support/Sources/AIProxy/MicrophonePCMSampleVendorError.swift
//

import Foundation

public enum MicrophonePCMSampleVendorError: LocalizedError {
    case couldNotConfigureAudioUnit(String)

    public var errorDescription: String? {
        switch self {
        case .couldNotConfigureAudioUnit(let message):
            return message
        }
    }
}