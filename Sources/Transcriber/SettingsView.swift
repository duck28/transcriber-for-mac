import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: TranscriptionModel

    var body: some View {
        Form {
            Picker("Appearance", selection: $model.appearance) {
                ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)

            Section("Speech Recognition") {
                Picker("Engine", selection: $model.speechEngine) {
                    ForEach(SpeechEngine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if model.usesWhisper {
                    Picker("Whisper model", selection: $model.whisperModel) {
                        ForEach(WhisperModel.allCases) { Text($0.title).tag($0) }
                    }
                    if model.whisperModel == .custom {
                        TextField("Hugging Face repository", text: $model.whisperCustomRepo,
                                  prompt: Text(WhisperModel.defaultRepo))
                        TextField("Model folder", text: $model.whisperCustomVariant,
                                  prompt: Text("openai_whisper-large-v3-v20240930_turbo"))
                    }
                    LabeledContent("Status") {
                        HStack {
                            Text(model.isWhisperModelDownloaded ? "On this Mac" : "Not downloaded")
                                .foregroundStyle(.secondary)
                            if !model.isWhisperModelDownloaded {
                                Button("Download", action: model.downloadWhisperModel)
                                    .disabled(!model.isIdle || model.whisperModelSource == nil)
                            }
                            Button("Show in Finder", action: model.revealWhisperModels)
                        }
                    }
                }
                Text(model.usesWhisper
                     ? "Whisper runs on this Mac and understands Swiss German and other dialects, writing them as Standard German (with Swiss spelling when German (Switzerland) is selected). The model is downloaded once. “Fast” is about twice as quick as full precision with nearly the same accuracy."
                     : "Apple Speech uses the Dictation models built into macOS. It's quick but doesn't understand dialects such as Swiss German.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(!model.isIdle)

            if model.usesWhisper {
                expertOptions
            }

            Section("Saving") {
                Toggle("Save transcripts automatically", isOn: $model.autosaveEnabled)
                Toggle("Save audio next to the transcript", isOn: $model.recordAudio)
                LabeledContent("Folder") {
                    HStack {
                        Text((model.saveFolder.path as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…", action: model.chooseSaveFolder)
                    }
                }
            }

            Section("Narrator Mode") {
                Picker("Subtitles", selection: $model.subtitleStyle) {
                    ForEach(SubtitleStyle.allCases) { Text($0.title).tag($0) }
                }
                Picker("Final Cut Pro frame rate", selection: $model.frameRate) {
                    ForEach(VideoFrameRate.allCases) { Text($0.title).tag($0) }
                }
                Text("Subtitles are saved as an .srt file next to the transcript. Changing the style re-flows the current subtitles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("YouTube") {
                TextField("yt-dlp location", text: $model.ytDLPPath, prompt: Text("Find automatically"))
                YTDLPStatus()
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Whisper's decoding and live-phrase parameters; the defaults apply while this is off.
    private var expertOptions: some View {
        Section("Expert Options") {
            Toggle("Change transcription parameters", isOn: $model.expertOptions)
            if model.expertOptions {
                numberField("Temperature", value: $model.whisperParameters.temperature)
                numberField("Temperature increase on retry", value: $model.whisperParameters.temperatureIncrementOnFallback)
                Stepper("Retries: \(model.whisperParameters.temperatureFallbackCount)",
                        value: $model.whisperParameters.temperatureFallbackCount, in: 0...10)
                numberField("Compression ratio threshold", value: $model.whisperParameters.compressionRatioThreshold)
                numberField("Log probability threshold", value: $model.whisperParameters.logProbThreshold)
                numberField("First word log probability threshold",
                            value: $model.whisperParameters.firstTokenLogProbThreshold)
                numberField("No-speech threshold", value: $model.whisperParameters.noSpeechThreshold)
                Toggle("Suppress blank output", isOn: $model.whisperParameters.suppressBlank)
                numberField("Pause that ends a phrase (seconds)", value: $model.whisperParameters.pauseInterval)
                numberField("Longest phrase (seconds)", value: $model.whisperParameters.maxPhraseDuration)
                numberField("Silence level", value: $model.whisperParameters.speechLevel)
                LabeledContent("Defaults") {
                    Button("Restore Defaults") { model.whisperParameters = .standard }
                        .disabled(model.whisperParameters == .standard)
                }
            }
            Text(model.expertOptions
                 ? "The defaults are WhisperKit's. A decoding is retried at a higher temperature when the text repeats itself (compression ratio) or Whisper is unsure (log probability). The phrase and silence settings apply to live transcription. Out-of-range values are kept within limits. Changes apply to the next transcription."
                 : "Transcriber uses WhisperKit's standard parameters. Turn this on to fine-tune them.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func numberField<Value: BinaryFloatingPoint>(_ title: String, value: Binding<Value>) -> some View {
        TextField(title, value: value, format: FloatingPointFormatStyle<Value>())
            .multilineTextAlignment(.trailing)
    }
}
