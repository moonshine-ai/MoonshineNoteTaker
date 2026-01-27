/*
See the LICENSE.txt file for this sample's licensing information.

Abstract:
A view for app settings including font, colors, and audio recording preferences.
*/

import SwiftUI
import AppKit

struct SettingsView: View {
    @AppStorage("fontSize") private var fontSize: Double = 14.0
    @AppStorage("fontFamily") private var fontFamily: String = "System"
    @AppStorage("fontColor") private var fontColorData: Data = Color.black.toData()
    @AppStorage("backgroundColor") private var backgroundColorData: Data = Color.white.toData()
    @AppStorage("recordMicAudio") private var recordMicAudio: Bool = false
    @AppStorage("recordSystemAudio") private var recordSystemAudio: Bool = true
    @AppStorage("enableEchoCancellation") private var enableEchoCancellation: Bool = true
    @AppStorage("saveAudioToFile") private var saveAudioToFile: Bool = true
    
    private var fontColor: Color {
        Color.fromData(fontColorData) ?? .black
    }
    
    private var backgroundColor: Color {
        Color.fromData(backgroundColorData) ?? .white
    }
    
    // Get available font families
    private var availableFontFamilies: [String] {
        var families = ["System"]
        families.append(contentsOf: NSFontManager.shared.availableFontFamilies.sorted())
        return families
    }
    
    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Font Family")
                            .frame(width: 120, alignment: .leading)
                        Picker("", selection: $fontFamily) {
                            ForEach(availableFontFamilies, id: \.self) { family in
                                Text(family).tag(family)
                            }
                        }
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    
                    HStack {
                        Text("Font Size")
                            .frame(width: 120, alignment: .leading)
                        HStack(spacing: 8) {
                            Slider(value: $fontSize, in: 8...72, step: 1)
                            Text("\(Int(fontSize))")
                                .frame(width: 35, alignment: .trailing)
                                .monospacedDigit()
                        }
                    }
                    
                    HStack {
                        Text("Font Color")
                            .frame(width: 120, alignment: .leading)
                        ColorPicker("", selection: Binding(
                            get: { fontColor },
                            set: { fontColorData = $0.toData() }
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Font Settings")
                    .font(.headline)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Background Color")
                            .frame(width: 120, alignment: .leading)
                        ColorPicker("", selection: Binding(
                            get: { backgroundColor },
                            set: { backgroundColorData = $0.toData() }
                        ))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Text("Appearance")
                    .font(.headline)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Transcribe Microphone Audio", isOn: $recordMicAudio)
                    Toggle("Transcribe System Audio", isOn: $recordSystemAudio)
                    Toggle("Enable Echo Cancellation", isOn: $enableEchoCancellation)
                    Toggle("Save Audio to File", isOn: $saveAudioToFile)
                }
                .padding(.vertical, 4)
            } header: {
                Text("Audio Recording")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .frame(width: 520, height: 500)
    }
}

// MARK: - Color Extension for Data Conversion

extension Color {
    func toData() -> Data {
        let nsColor = NSColor(self)
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: nsColor, requiringSecureCoding: false) {
            return colorData
        }
        return NSColor.black.toData()
    }
    
    static func fromData(_ data: Data) -> Color? {
        if let nsColor = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSColor.self, from: data) {
            return Color(nsColor)
        }
        return nil
    }
}

extension NSColor {
    func toData() -> Data {
        if let colorData = try? NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false) {
            return colorData
        }
        return try! NSKeyedArchiver.archivedData(withRootObject: NSColor.black, requiringSecureCoding: false)
    }
}

extension Color {
    func toNSColor() -> NSColor {
        return NSColor(self)
    }
}
