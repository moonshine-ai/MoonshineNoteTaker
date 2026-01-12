/*
See the LICENSE.txt file for this sample’s licensing information.

Abstract:
A model object that provides the interface to capture screen content and system audio.
*/
import Foundation
@preconcurrency import ScreenCaptureKit
import Combine
import OSLog
import SwiftUI
import MoonshineVoice

@MainActor
class ScreenRecorder: NSObject,
                      ObservableObject,
                      SCContentSharingPickerObserver {
    /// The supported capture types.
    enum CaptureType {
        case display
        case window
    }
    
    enum DynamicRangePreset: String, CaseIterable {
        case localDisplayHDR = "Local Display HDR"
        case canonicalDisplayHDR = "Canonical Display HDR"
        
        @available(macOS 15.0, *)
        var scDynamicRangePreset: SCStreamConfiguration.Preset? {
            switch self {
            case .localDisplayHDR:
                return SCStreamConfiguration.Preset.captureHDRStreamLocalDisplay
            case .canonicalDisplayHDR:
                return SCStreamConfiguration.Preset.captureHDRStreamCanonicalDisplay
            }
        }
    }
    
    private let logger = Logger()
    
    @Published var isRunning = false
    
    // MARK: - Video Properties
    @Published var captureType: CaptureType = .display {
        didSet { updateEngine() }
    }
    
    @Published var selectedDisplay: SCDisplay? {
        didSet { updateEngine() }
    }
    
    @Published var selectedWindow: SCWindow? {
        didSet { updateEngine() }
    }
    
    @Published var isAppExcluded = true {
        didSet { updateEngine() }
    }

    // MARK: - SCContentSharingPicker Properties
    @Published var maximumStreamCount = Int() {
        didSet { updatePickerConfiguration() }
    }
    @Published var excludedWindowIDsSelection = Set<Int>() {
        didSet { updatePickerConfiguration() }
    }

    @Published var excludedBundleIDsList = [String]() {
        didSet { updatePickerConfiguration() }
    }

    @Published var allowsRepicking = true {
        didSet { updatePickerConfiguration() }
    }

    @Published var allowedPickingModes = SCContentSharingPickerMode() {
        didSet { updatePickerConfiguration() }
    }
    
    // MARK: - HDR Preset
    @Published var selectedDynamicRangePreset: DynamicRangePreset? {
        didSet { updateEngine() }
    }
    @Published var contentSize = CGSize(width: 1, height: 1)
    private var scaleFactor: Int { Int(NSScreen.main?.backingScaleFactor ?? 2) }
    
    /// A view that renders the screen content.
    lazy var capturePreview: CapturePreview = {
        CapturePreview()
    }()
    private let screenRecorderPicker = SCContentSharingPicker.shared
    private var availableApps = [SCRunningApplication]()
    @Published private(set) var availableDisplays = [SCDisplay]()
    @Published private(set) var availableWindows = [SCWindow]()
    @Published private(set) var pickerUpdate: Bool = false // Update the running stream immediately with picker selection
    private var pickerContentFilter: SCContentFilter?
    private var shouldUsePickerFilter = false

    @Published var isPickerActive = false {
        didSet {
            if isPickerActive {
                logger.info("Picker is active")
                self.initializePickerConfiguration()
                self.screenRecorderPicker.isActive = true
                self.screenRecorderPicker.add(self)
            } else {
                logger.info("Picker is inactive")
                self.screenRecorderPicker.isActive = false
                self.screenRecorderPicker.remove(self)
            }
        }
    }

    // MARK: - Audio Properties
    @Published var isAudioCaptureEnabled = true {
        didSet {
            updateEngine()
        }
    }
    @Published var microphoneId: String?
    @Published var isMicCaptureEnabled = false {
        didSet {
            if isMicCaptureEnabled {
                addMicrophoneOutput()
            } else {
                removeMicrophoneOutput()
            }
            updateEngine()
        }
    }
    @Published var isRecordingStream = false {
        didSet {
            if isRecordingStream {
                try? initRecordingOutput()
                Task {
                    try await startRecordingOutput()
                }
            } else {
                try? stopRecordingOutput()
            }
        }
    }
    @Published var isAppAudioExcluded = false { didSet { updateEngine() } }
    
    /// The transcript document that holds all transcript lines.
    @Published var transcriptDocument = TranscriptDocument()
    
    private let recordingOutputPath: String? = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).last
    private var recordingOutput: SCRecordingOutput?
    
    // The object that manages the SCStream.
    private let captureEngine = CaptureEngine()
    
    private var isSetup = false
    
    // Combine subscribers.
    private var subscriptions = Set<AnyCancellable>()
    
    var canRecord: Bool {
        get async {
            do {
                // If the app doesn't have screen recording permission, this call generates an exception.
                try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                return true
            } catch {
                return false
            }
        }
    }
    
    func monitorAvailableContent() async {
        guard !isSetup || !isPickerActive else { return }
        // Refresh the lists of capturable content.
        await self.refreshAvailableContent()
        Timer.publish(every: 3, on: .main, in: .common).autoconnect().sink { [weak self] _ in
            guard let self = self else { return }
            Task {
                await self.refreshAvailableContent()
            }
        }
        .store(in: &subscriptions)
    }
    
    /// Starts capturing screen content.
    func start() async {
        // Exit early if already running.
        guard !isRunning else { return }
        
        if !isSetup {
            // Starting polling for available screen content.
            await monitorAvailableContent()
            isSetup = true
        }
        
        // Start the transcript document session
        transcriptDocument.startSession()
        
        // Connect the transcript document to the capture engine
        captureEngine.setTranscriptDocument(transcriptDocument)
        
        // If the user enables audio capture, start monitoring the audio stream.
        if isAudioCaptureEnabled {
            initializeTranscription()
        }
        
        do {
            let config = streamConfiguration
            let filter = contentFilter
            // Update the running state.
            isRunning = true
            setPickerUpdate(false)
            // Start the stream and await new video frames.
            for try await frame in captureEngine.startCapture(configuration: config, filter: filter) {
                capturePreview.updateFrame(frame)
                if contentSize != frame.size {
                    // Update the content size if it changed.
                    contentSize = frame.size
                }
            }
        } catch {
            logger.error("\(error.localizedDescription)")
            // Unable to start the stream. Set the running state to false.
            isRunning = false
        }
    }
    
    /// Stops capturing screen content.
    func stop() async {
        guard isRunning else { return }
        await captureEngine.stopCapture()
        try? stopRecordingOutput()
        removeMicrophoneOutput()
        // Stop transcription
        try? captureEngine.stopTranscription()
        // End the transcript document session
        transcriptDocument.endSession()
        isRunning = false
    }
    
    func openRecordingFolder() {
        if let recordingOutputPath = recordingOutputPath {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: recordingOutputPath)
        }
    }
            
    private func addMicrophoneOutput() {
        streamConfiguration.captureMicrophone = true
    }
    private func removeMicrophoneOutput() {
        streamConfiguration.captureMicrophone = false
        streamConfiguration.microphoneCaptureDeviceID = nil
    }
    
    private func initRecordingOutput() throws {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let currentDateTime = dateFormatter.string(from: Date())
        if let recordingOutputPath = recordingOutputPath {
            let outputPath = "\(recordingOutputPath)/recorded_output_\(currentDateTime).mp4"
            let outputURL = URL(fileURLWithPath: outputPath)
            let recordingConfiguration = SCRecordingOutputConfiguration()
            recordingConfiguration.outputURL = outputURL
            guard let recordingOutput = (SCRecordingOutput(configuration: recordingConfiguration, delegate: self) as SCRecordingOutput?)
            else {
                throw SCScreenRecordingError.failedToStartRecording("Failed to init recording output!")
            }
            logger.log("Initialized recording output with URL \(outputURL)")
            self.recordingOutput = recordingOutput
        }
    }
    
    private func startRecordingOutput() async throws {
        guard let recordingOutput = self.recordingOutput else {
            throw SCScreenRecordingError.failedToStartRecording("Recording output is empty!")
        }
        
        try? await captureEngine.addRecordOutputToStream(recordingOutput)
        logger.log("Added recording output \(String(describing: self.recordingOutput)) successfully to stream")
        recordingOutputDidStartRecording(recordingOutput)
    }
    
    private func stopRecordingOutput() throws {
        if let recordingOutput = self.recordingOutput {
            logger.log("Stopping recording output \(recordingOutput)")
            try? captureEngine.stopRecordingOutputForStream(recordingOutput)
            recordingOutputDidFinishRecording(recordingOutput)
        }
        self.recordingOutput = nil
    }
    
    private func updateEngine() {
        guard isRunning else { return }
        Task {
            let filter = contentFilter
            await captureEngine.update(configuration: streamConfiguration, filter: filter)
            setPickerUpdate(false)
        }
    }

    // MARK: - Content-sharing Picker
    private func initializePickerConfiguration() {
        var initialConfiguration = SCContentSharingPickerConfiguration()
        // Set the allowedPickerModes from the app.
        initialConfiguration.allowedPickerModes = [
            .singleWindow,
            .multipleWindows,
            .singleApplication,
            .multipleApplications,
            .singleDisplay
        ]
        self.allowedPickingModes = initialConfiguration.allowedPickerModes
    }

    private func updatePickerConfiguration() {
        self.screenRecorderPicker.maximumStreamCount = maximumStreamCount
        // Update the default picker configuration to pass to Control Center.
        self.screenRecorderPicker.defaultConfiguration = pickerConfiguration
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        logger.info("Picker canceled for stream \(stream)")
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in
            pickerContentFilter = filter
            shouldUsePickerFilter = true
            setPickerUpdate(true)
            updateEngine()
        }
        logger.info("Picker updated with filter=\(filter) for stream=\(stream)")
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        logger.error("Error starting picker! \(error)")
    }

    func setPickerUpdate(_ update: Bool) {
        Task { @MainActor in
            self.pickerUpdate = update
        }
    }

    func presentPicker() {
        if let stream = captureEngine.stream {
            SCContentSharingPicker.shared.present(for: stream)
        } else {
            SCContentSharingPicker.shared.present()
        }
    }

    private var pickerConfiguration: SCContentSharingPickerConfiguration {
        var config = SCContentSharingPickerConfiguration()
        config.allowedPickerModes = allowedPickingModes
        config.excludedWindowIDs = Array(excludedWindowIDsSelection)
        config.excludedBundleIDs = excludedBundleIDsList
        config.allowsChangingSelectedContent = allowsRepicking
        return config
    }

    private var contentFilter: SCContentFilter {
        var filter: SCContentFilter
        switch captureType {
        case .display:
            guard let display = selectedDisplay else { fatalError("No display selected.") }
            
            var excludedApps = [SCRunningApplication]()
            // If a user chooses to exclude the app from the stream,
            // exclude it by matching its bundle identifier.
            if isAppExcluded {
                excludedApps = availableApps.filter { app in
                    Bundle.main.bundleIdentifier == app.bundleIdentifier
                }
            }
            // Create a content filter with excluded apps.
            filter = SCContentFilter(display: display,
                                     excludingApplications: excludedApps,
                                     exceptingWindows: [])
        case .window:
            guard let window = selectedWindow else { fatalError("No window selected.") }
            // Create a content filter that includes a single window.
            filter = SCContentFilter(desktopIndependentWindow: window)
        }
        // Use filter from content picker, if active.
        if shouldUsePickerFilter {
            guard let pickerFilter = pickerContentFilter else { return filter }
            filter = pickerFilter
            shouldUsePickerFilter = false
        }
        return filter
    }
    
    private var streamConfiguration: SCStreamConfiguration {
        
        var streamConfig = SCStreamConfiguration()
        
        if let dynamicRangePreset = selectedDynamicRangePreset?.scDynamicRangePreset {
            streamConfig = SCStreamConfiguration(preset: dynamicRangePreset)
        }
        
        // Configure audio capture.
        streamConfig.capturesAudio = isAudioCaptureEnabled
        streamConfig.excludesCurrentProcessAudio = isAppAudioExcluded
        streamConfig.captureMicrophone = isMicCaptureEnabled
        
        // Configure the display content width and height.
        if captureType == .display, let display = selectedDisplay {
            streamConfig.width = display.width * scaleFactor
            streamConfig.height = display.height * scaleFactor
        }
        
        // Configure the window content width and height.
        if captureType == .window, let window = selectedWindow {
            streamConfig.width = Int(window.frame.width) * 2
            streamConfig.height = Int(window.frame.height) * 2
        }
        
        // Set the capture interval at 60 fps.
        streamConfig.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        
        // Increase the depth of the frame queue to ensure high fps at the expense of increasing
        // the memory footprint of WindowServer.
        streamConfig.queueDepth = 5
        
        return streamConfig
    }
    
    private func refreshAvailableContent() async {
        do {
            // Retrieve the available screen content to capture.
            let availableContent = try await SCShareableContent.excludingDesktopWindows(false,
                                                                                        onScreenWindowsOnly: true)
            availableDisplays = availableContent.displays
            
            let windows = filterWindows(availableContent.windows)
            if windows != availableWindows {
                availableWindows = windows
            }
            availableApps = availableContent.applications
            
            if selectedDisplay == nil {
                selectedDisplay = availableDisplays.first
            }
            if selectedWindow == nil {
                selectedWindow = availableWindows.first
            }
        } catch {
            logger.error("Failed to get the shareable content: \(error.localizedDescription)")
        }
    }
    
    private func filterWindows(_ windows: [SCWindow]) -> [SCWindow] {
        windows
        // Sort the windows by app name.
            .sorted { $0.owningApplication?.applicationName ?? "" < $1.owningApplication?.applicationName ?? "" }
        // Remove windows that don't have an associated .app bundle.
            .filter { $0.owningApplication != nil && $0.owningApplication?.applicationName != "" }
        // Remove this app's window from the list.
            .filter { $0.owningApplication?.bundleIdentifier != Bundle.main.bundleIdentifier }
    }
    
    /// Initialize transcription with Moonshine Voice.
    /// Attempts to find the model path from the Moonshine framework bundle.
    private func initializeTranscription() {
        // Try to find the model path from the Moonshine framework bundle
        let modelPath = findMoonshineModelPath()
        
        guard let modelPath = modelPath else {
            logger.warning("Could not find Moonshine model path. Transcription will not be available.")
            print("[TRANSCRIPT ERROR] Could not find Moonshine model path. Please ensure the Moonshine Voice package is properly configured.")
            return
        }
        
        do {
            try captureEngine.initializeTranscriber(modelPath: modelPath)
            try captureEngine.startTranscription()
            logger.info("Transcription initialized and started with model path: \(modelPath)")
            print("[TRANSCRIPT] Initialized Moonshine Voice transcription")
        } catch {
            logger.error("Failed to initialize transcription: \(error.localizedDescription)")
            print("[TRANSCRIPT ERROR] Failed to initialize transcription: \(error.localizedDescription)")
        }
    }
    
    /// Find the Moonshine model path from the framework bundle.
    /// - Returns: Path to the model directory, or nil if not found
    private func findMoonshineModelPath() -> String? {
        // First, try using Transcriber's frameworkBundle helper
        if let frameworkBundle = Transcriber.frameworkBundle {
            if let modelPath = findModelPathInBundle(frameworkBundle) {
                return modelPath
            }
        }
        
        // Try to get the framework bundle by identifier
        if let frameworkBundle = Bundle(identifier: "ai.moonshine.voice") {
            if let modelPath = findModelPathInBundle(frameworkBundle) {
                return modelPath
            }
        }
        
        // Fallback: try to find the framework bundle by searching in main bundle
        if let frameworkPath = Bundle.main.path(forResource: "Moonshine", ofType: "framework"),
           let bundle = Bundle(path: frameworkPath) {
            if let modelPath = findModelPathInBundle(bundle) {
                return modelPath
            }
        }
        
        // Last resort: check if there's a model path environment variable or user defaults
        if let envPath = ProcessInfo.processInfo.environment["MOONSHINE_MODEL_PATH"],
           FileManager.default.fileExists(atPath: envPath) {
            return envPath
        }
        
        return nil
    }
    
    /// Find the model path within a bundle.
    /// - Parameter bundle: The bundle to search
    /// - Returns: Path to the model directory, or nil if not found
    private func findModelPathInBundle(_ bundle: Bundle) -> String? {
        let modelDir = "models"
        let modelName = "base-en"
        if let fullURL = bundle.url(forResource: "\(modelDir)/\(modelName)", withExtension: nil) {
            let modelPath = fullURL.path
            if FileManager.default.fileExists(atPath: modelPath) {
                return modelPath
            }
        }
        
        // Alternative: look for base-en directly in resources
        if let modelNameURL = bundle.url(forResource: modelName, withExtension: nil) {
            let modelPath = modelNameURL.path
            if FileManager.default.fileExists(atPath: modelPath) {
                return modelPath
            }
        }
        
//        // If model is not in bundle, try to find it relative to the framework
//        if let resourcePath = bundle.resourcePath {
//            let possiblePaths = [
//                (resourcePath as NSString).appendingPathComponent("test-assets/tiny-en"),
//                (resourcePath as NSString).appendingPathComponent("tiny-en")
//            ]
//            
//            for path in possiblePaths {
//                if FileManager.default.fileExists(atPath: path) {
//                    return path
//                }
//            }
//        }
        
        return nil
    }
}

extension SCWindow {
    var displayName: String {
        switch (owningApplication, title) {
        case (.some(let application), .some(let title)):
            return "\(application.applicationName): \(title)"
        case (.none, .some(let title)):
            return title
        case (.some(let application), .none):
            return "\(application.applicationName): \(windowID)"
        default:
            return ""
        }
    }
}

extension SCDisplay {
    var displayName: String {
        "Display: \(width) x \(height)"
    }
}

extension ScreenRecorder: SCRecordingOutputDelegate {
    // MARK: SCRecordingOutputDelegate
    @available(macOS 15.0, *)
    nonisolated func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {
        logger.log("Recording output \(recordingOutput) did start recording")
    }

    @available(macOS 15.0, *)
    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        logger.log("Recording output \(recordingOutput) did finish recording")
    }
}

enum SCScreenRecordingError: Error {
    case failedToStartRecording(String)
}
