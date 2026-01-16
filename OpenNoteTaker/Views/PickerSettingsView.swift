/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A view for content picker configuration.
*/

import SwiftUI
import ScreenCaptureKit

struct PickerSettingsView: View {

    private let verticalLabelSpacing: CGFloat = 8

    @Environment(\.presentationMode) var presentation
    @ObservedObject var screenRecorder: ScreenRecorder
    @State private var bundleIDToExclude = ""
    @State private var maxStreamCount = 3

    func addBundleID() {
        guard !bundleIDToExclude.isEmpty else { return }
        screenRecorder.excludedBundleIDsList.insert(bundleIDToExclude, at: 0)
        bundleIDToExclude = ""
    }

    func clearBundleIDs() {
        screenRecorder.excludedBundleIDsList = []
    }

    private func bindingForPickingModes(_ mode: SCContentSharingPickerMode) -> Binding<Bool> {
        Binding {
            screenRecorder.allowedPickingModes.contains(mode)
        } set: { isOn in
            if isOn {
                screenRecorder.allowedPickingModes.insert(mode)
            } else {
                screenRecorder.allowedPickingModes.remove(mode)
            }
        }
    }

    var body: some View {
        Group {
            VStack(alignment: .leading, spacing: verticalLabelSpacing) {

                // Picker property: Maximum stream count.
                TextField("Maximum Stream Count", value: $maxStreamCount, format: .number)
                    .frame(maxWidth: 150)
                    .onSubmit {
                        screenRecorder.maximumStreamCount = maxStreamCount
                    }

                // Picker configuration: Allowed picking modes.
                Toggle("Single Window", isOn: bindingForPickingModes(.singleWindow))
                Toggle("Multiple Windows", isOn: bindingForPickingModes(.multipleWindows))
                Toggle("Single Application", isOn: bindingForPickingModes(.singleApplication))
                Toggle("Multiple Applications", isOn: bindingForPickingModes(.multipleApplications))
                Toggle("Single Display", isOn: bindingForPickingModes(.singleDisplay))

                // Picker configuration: Excluded Window IDs.
                Text("Select window below to exclude it:")
                    .font(.subheadline)
                    .foregroundStyle(.primary)
                List(screenRecorder.availableWindows, id: \.self, selection: $screenRecorder.excludedWindowIDsSelection) { window in
                    let windowID = Int(window.windowID)
                    var windowIsExcluded = screenRecorder.excludedWindowIDsSelection.contains(windowID)
                    Button {
                        if !windowIsExcluded {
                            screenRecorder.excludedWindowIDsSelection.insert(windowID)
                        } else {
                            screenRecorder.excludedWindowIDsSelection.remove(windowID)
                        }
                        windowIsExcluded.toggle()
                    } label: {
                        Image(systemName: windowIsExcluded ? "x.circle.fill" : "checkmark.circle.fill")
                            .foregroundStyle(.white, windowIsExcluded ? .red : .green)
                        Text(window.displayName)
                    }
                    .cornerRadius(5)
                }
                .onAppear {
                    Task {
                        await screenRecorder.monitorAvailableContent()
                    }
                }

                // Picker configuration: Excluded Bundle IDs.
                HStack {
                    TextField("\(Bundle.main.bundleIdentifier!)", text: $bundleIDToExclude)
                        .frame(maxWidth: 300)
                        .onSubmit {
                            addBundleID()
                        }
                }
                if !screenRecorder.excludedBundleIDsList.isEmpty {
                    ScrollView {
                        BundleIDsListView(screenRecorder: screenRecorder)
                    }
                    .frame(maxWidth: 300, maxHeight: 50)
                    .background(MaterialView())
                    .clipShape(.rect(cornerSize: CGSize(width: 1, height: 1)))
                    Button("Clear All Bundle IDs") {
                        clearBundleIDs()
                    }
                }

                // Picker configuration: Allows Repicking.
                Toggle("Allows Repicking", isOn: $screenRecorder.allowsRepicking)
                    .toggleStyle(.switch)
            }
            // Dismiss the PickerSettingsView.
            HStack {
                Button {
                    presentation.wrappedValue.dismiss()
                } label: {
                    Text("Dismiss")
                }
            }
        }
        .padding()
    }
}

struct BundleIDsListView: View {
    @ObservedObject var screenRecorder: ScreenRecorder

    var body: some View {
        Section {
            ForEach(Array(screenRecorder.excludedBundleIDsList.enumerated()), id: \.element) { index, element in
                HStack {
                    Text("\(element)")
                        .padding(.leading, 5)
                        .foregroundColor(.gray)
                    Spacer()
                    Button {
                        screenRecorder.excludedBundleIDsList.remove(at: index)
                    } label: {
                        Image(systemName: "xmark.circle")
                    }
                    .padding(.trailing, 10)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
                }
            }
        }
    }
}
