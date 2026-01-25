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
            Section("Font Settings") {
                Picker("Font Family", selection: $fontFamily) {
                    ForEach(availableFontFamilies, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                
                HStack {
                    Text("Font Size")
                    Spacer()
                    Slider(value: $fontSize, in: 8...72, step: 1)
                    Text("\(Int(fontSize))")
                        .frame(width: 40)
                }
                
                ColorPicker("Font Color", selection: Binding(
                    get: { fontColor },
                    set: { fontColorData = $0.toData() }
                ))
            }
            
            Section("Appearance") {
                ColorPicker("Background Color", selection: Binding(
                    get: { backgroundColor },
                    set: { backgroundColorData = $0.toData() }
                ))
            }
            
            Section("Audio Recording") {
                Toggle("Record Microphone Audio", isOn: $recordMicAudio)
                Toggle("Record System Audio", isOn: $recordSystemAudio)
            }
        }
        .padding()
        .frame(width: 500, height: 400)
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
