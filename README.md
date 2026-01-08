# Capturing screen content in macOS

Stream desktop content like displays, apps, and windows by adopting screen capture in your app.

For more information about the app and how it works, see
[Capturing screen content in macOS](https://developer.apple.com/documentation/ScreenCaptureKit/Capturing-screen-content-in-macOS)
in the developer documentation.

## Moonshine Voice Transcription Integration

This example has been updated to integrate with Moonshine Voice for real-time audio transcription. When audio capture is enabled, captured audio is automatically transcribed and transcript line text changes and completions are printed to the Xcode debug console.

### Setup Instructions

1. **Add Moonshine Voice Package Dependency:**
   - Open the project in Xcode
   - Go to File → Add Package Dependencies...
   - Add the Moonshine Voice package:
     - If using a local path: `file:///Users/petewarden/projects/moonshine-v2/swift`
     - Or add the remote URL if available
   - Select the `MoonshineVoice` product and add it to the `CaptureSample` target

2. **Model Path Configuration:**
   - The app will automatically attempt to find the Moonshine model files from the framework bundle
   - If the model path cannot be found automatically, you can set the `MOONSHINE_MODEL_PATH` environment variable to point to the directory containing the model files (e.g., `tiny-en` directory)
   - The model path should point to a directory containing model files like `decoder_model_merged.ort`, `encoder_model.ort`, and `tokenizer.bin`

3. **Usage:**
   - Enable audio capture in the app
   - Start screen capture
   - Transcript events will appear in the Xcode debug console:
     - `[TRANSCRIPT TEXT CHANGED]` - When transcript line text is updated
     - `[TRANSCRIPT COMPLETED]` - When a transcript line is finalized
     - `[TRANSCRIPT LINE STARTED]` - When a new transcript line begins
     - `[TRANSCRIPT ERROR]` - If any errors occur

### Implementation Details

- **AudioTranscriber.swift**: Manages Moonshine Voice transcription, converts audio buffers, and handles transcript events
- **CaptureEngine.swift**: Feeds captured audio buffers to the transcriber
- **ScreenRecorder.swift**: Initializes and manages the transcription lifecycle

The transcription automatically starts when audio capture is enabled and stops when capture stops.
