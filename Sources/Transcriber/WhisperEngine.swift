import Foundation
import WhisperKit

/// Which speech recognizer transcribes. Both run on this Mac.
enum SpeechEngine: String, CaseIterable, Identifiable {
    /// macOS speech recognition (the Dictation models).
    case apple
    /// OpenAI's Whisper through WhisperKit (Core ML). Understands dialects such as Swiss German far better.
    case whisper

    var id: Self { self }

    var title: String {
        switch self {
        case .apple: return "Apple Speech"
        case .whisper: return "Whisper"
        }
    }
}

/// Whisper models Transcriber offers, as folders of the `argmaxinc/whisperkit-coreml` Hugging Face repository.
enum WhisperModel: String, CaseIterable, Identifiable {
    case turboCompressed = "openai_whisper-large-v3-v20240930_turbo_632MB"
    case turbo = "openai_whisper-large-v3-v20240930_turbo"
    case small = "openai_whisper-small"
    /// Any WhisperKit-compatible model, such as a Swiss German fine-tune converted with whisperkittools.
    case custom

    static let defaultRepo = "argmaxinc/whisperkit-coreml"

    var id: Self { self }

    var title: String {
        switch self {
        case .turboCompressed: return "Large v3 Turbo – fast (≈ 650 MB)"
        case .turbo: return "Large v3 Turbo – full precision (≈ 1.6 GB)"
        case .small: return "Small (≈ 500 MB)"
        case .custom: return "Custom…"
        }
    }
}

/// Decoding and live-phrase parameters, changeable under Settings › Expert Options.
/// The defaults are WhisperKit's decoding defaults and the live timing Transcriber has always used.
struct WhisperParameters: Codable, Equatable, Sendable {
    var temperature: Float = 0
    /// Added to the temperature for each retry when decoding fails.
    var temperatureIncrementOnFallback: Float = 0.2
    var temperatureFallbackCount = 5
    /// Above this the text counts as repetitive and decoding is retried.
    var compressionRatioThreshold: Float = 2.4
    /// Below this average log probability decoding is retried.
    var logProbThreshold: Float = -1
    var firstTokenLogProbThreshold: Float = -1.5
    /// Segments more likely than this to be silence are dropped.
    var noSpeechThreshold: Float = 0.6
    var suppressBlank = false
    /// Live: seconds of silence that end a phrase.
    var pauseInterval: TimeInterval = 0.6
    /// Live: phrases longer than this are split. Stays under Whisper's 30-second window.
    var maxPhraseDuration: TimeInterval = 15
    /// Live: below this level (RMS) audio counts as silence.
    var speechLevel: Float = 0.006

    static let standard = WhisperParameters()

    init() {}

    /// Parameters added in later versions get their defaults when older settings are read.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let standard = WhisperParameters()
        temperature = try container.decodeIfPresent(Float.self, forKey: .temperature) ?? standard.temperature
        temperatureIncrementOnFallback = try container.decodeIfPresent(Float.self, forKey: .temperatureIncrementOnFallback)
            ?? standard.temperatureIncrementOnFallback
        temperatureFallbackCount = try container.decodeIfPresent(Int.self, forKey: .temperatureFallbackCount)
            ?? standard.temperatureFallbackCount
        compressionRatioThreshold = try container.decodeIfPresent(Float.self, forKey: .compressionRatioThreshold)
            ?? standard.compressionRatioThreshold
        logProbThreshold = try container.decodeIfPresent(Float.self, forKey: .logProbThreshold) ?? standard.logProbThreshold
        firstTokenLogProbThreshold = try container.decodeIfPresent(Float.self, forKey: .firstTokenLogProbThreshold)
            ?? standard.firstTokenLogProbThreshold
        noSpeechThreshold = try container.decodeIfPresent(Float.self, forKey: .noSpeechThreshold) ?? standard.noSpeechThreshold
        suppressBlank = try container.decodeIfPresent(Bool.self, forKey: .suppressBlank) ?? standard.suppressBlank
        pauseInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .pauseInterval) ?? standard.pauseInterval
        maxPhraseDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .maxPhraseDuration)
            ?? standard.maxPhraseDuration
        speechLevel = try container.decodeIfPresent(Float.self, forKey: .speechLevel) ?? standard.speechLevel
    }

    /// The same parameters, kept to sensible ranges (they're typed in by hand).
    var clamped: WhisperParameters {
        var p = self
        p.temperature = min(max(p.temperature, 0), 1)
        p.temperatureIncrementOnFallback = min(max(p.temperatureIncrementOnFallback, 0), 1)
        p.temperatureFallbackCount = min(max(p.temperatureFallbackCount, 0), 10)
        p.compressionRatioThreshold = min(max(p.compressionRatioThreshold, 0), 10)
        p.logProbThreshold = min(max(p.logProbThreshold, -10), 0)
        p.firstTokenLogProbThreshold = min(max(p.firstTokenLogProbThreshold, -10), 0)
        p.noSpeechThreshold = min(max(p.noSpeechThreshold, 0), 1)
        p.pauseInterval = min(max(p.pauseInterval, 0.2), 5)
        p.maxPhraseDuration = min(max(p.maxPhraseDuration, 5), 28)
        p.speechLevel = min(max(p.speechLevel, 0), 0.1)
        return p
    }
}

/// Runs Whisper on this Mac. The model is downloaded from Hugging Face once, then everything happens offline.
///
/// One model is kept loaded at a time and shared by live and file transcription.
actor WhisperEngine {
    static let shared = WhisperEngine()

    /// Where a model comes from: a Hugging Face repository and the model's folder in it.
    struct ModelSource: Equatable, Sendable {
        var repo: String
        var variant: String
    }

    enum EngineError: LocalizedError {
        case noModel

        var errorDescription: String? {
            switch self {
            case .noModel: return "Choose a Whisper model in Settings › Speech Recognition."
            }
        }
    }

    /// A recognized stretch of audio. Word times are seconds from the start of the samples.
    struct Recognition: Sendable {
        let text: String
        let words: [TimedWord]
    }

    private var loaded: (source: ModelSource, kit: WhisperKit)?
    private var loading: (source: ModelSource, task: Task<WhisperKit, Error>)?

    /// ~/Library/Application Support/Transcriber/Whisper
    static var modelsFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber/Whisper", isDirectory: true)
    }

    /// The model's folder once it has been downloaded.
    static func localFolder(for source: ModelSource) -> URL? {
        let folder = modelsFolder.appendingPathComponent("models/\(source.repo)/\(source.variant)", isDirectory: true)
        let encoder = folder.appendingPathComponent("AudioEncoder.mlmodelc")
        return FileManager.default.fileExists(atPath: encoder.path) ? folder : nil
    }

    static func isDownloaded(_ source: ModelSource) -> Bool { localFolder(for: source) != nil }

    /// Whisper's code for the locale's language ("de" for German (Switzerland)), or nil if Whisper doesn't know it.
    static func languageCode(for locale: Locale) -> String? {
        guard let code = locale.language.languageCode?.identifier else { return nil }
        return Constants.languageCodes.contains(code) ? code : nil
    }

    func isLoaded(_ source: ModelSource) -> Bool { loaded?.source == source }

    /// Downloads (first time only) and loads the model. `onProgress` gets the download progress (0...1),
    /// then nil while the model is being prepared for this Mac, which can take a few minutes the first time.
    func prepare(_ source: ModelSource, onProgress: @escaping @Sendable (Double?) -> Void = { _ in }) async throws {
        if loaded?.source == source { return }
        if let loading, loading.source == source {
            _ = try await Self.value(of: loading.task)
            return
        }
        let task = Task { () throws -> WhisperKit in
            let folder: URL
            if let local = Self.localFolder(for: source) {
                folder = local
            } else {
                folder = try await WhisperKit.download(variant: source.variant, downloadBase: Self.modelsFolder,
                                                       from: source.repo) { onProgress($0.fractionCompleted) }
            }
            onProgress(nil)
            let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: Self.modelsFolder,
                                          verbose: false, load: true, download: false)
            let kit = try await WhisperKit(config)
            // The first recognition after loading is several times slower; get it out of the way now.
            _ = try? await kit.transcribe(audioArray: [Float](repeating: 0, count: WhisperKit.sampleRate))
            return kit
        }
        loading = (source, task)
        defer { if loading?.source == source { loading = nil } }
        let kit = try await Self.value(of: task)
        // Only one model stays in memory.
        loaded = (source, kit)
    }

    /// Waits for `task`, cancelling it if the caller is cancelled (which stops a download).
    private static func value(of task: Task<WhisperKit, Error>) async throws -> WhisperKit {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Recognizes 16 kHz mono samples. `swissSpelling` writes "ss" instead of "ß", as in Switzerland.
    /// Decoding ends early (with the text so far) once `shouldStop` returns true.
    func transcribe(_ samples: [Float], language: String?, swissSpelling: Bool, wordTimestamps: Bool,
                    parameters: WhisperParameters = .standard,
                    shouldStop: (@Sendable () -> Bool)? = nil) async throws -> Recognition? {
        guard let kit = loaded?.kit else { throw EngineError.noModel }
        let options = DecodingOptions(language: language,
                                      temperature: parameters.temperature,
                                      temperatureIncrementOnFallback: parameters.temperatureIncrementOnFallback,
                                      temperatureFallbackCount: parameters.temperatureFallbackCount,
                                      detectLanguage: language == nil,
                                      skipSpecialTokens: true, wordTimestamps: wordTimestamps,
                                      suppressBlank: parameters.suppressBlank,
                                      compressionRatioThreshold: parameters.compressionRatioThreshold,
                                      logProbThreshold: parameters.logProbThreshold,
                                      firstTokenLogProbThreshold: parameters.firstTokenLogProbThreshold,
                                      noSpeechThreshold: parameters.noSpeechThreshold,
                                      chunkingStrategy: .none)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options,
                                               callback: shouldStop.map { stop in { _ in stop() ? false : nil } })
        // Whisper invents text for silence and noise ("Untertitel im Auftrag des ZDF"); drop such segments.
        let segments = results.flatMap(\.segments).filter {
            $0.noSpeechProb < parameters.noSpeechThreshold && !Self.isHallucination($0.text)
        }

        func clean(_ text: String) -> String {
            let stripped = Self.removingSpecialTokens(text)
            return swissSpelling ? stripped.replacingOccurrences(of: "ß", with: "ss") : stripped
        }
        let text = segments.map { clean($0.text).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let words = segments.flatMap { $0.words ?? [] }.compactMap { word -> TimedWord? in
            let text = clean(word.word).trimmingCharacters(in: .whitespaces)
            return text.isEmpty ? nil : TimedWord(text: text, start: TimeInterval(word.start), end: TimeInterval(word.end))
        }
        return Recognition(text: text, words: words)
    }

    private static func removingSpecialTokens(_ text: String) -> String {
        text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
    }

    /// Phrases Whisper is known to produce from silence, applause or music (learned from subtitled TV).
    private static let hallucinations = [
        "untertitel im auftrag des zdf", "untertitel der amara.org-community", "untertitelung des zdf",
        "vielen dank fürs zuschauen", "danke fürs zuschauen", "copyright wdr", "swr 2020", "swr 2021",
        "thanks for watching", "thank you for watching", "subtitles by the amara.org community",
    ]

    private static func isHallucination(_ text: String) -> Bool {
        let stripped = removingSpecialTokens(text).trimmingCharacters(in: .whitespacesAndNewlines)
        // Sound descriptions such as "[Musik]" or "(Applaus)".
        if stripped.range(of: #"^[\[(*♪].*[\])*♪]$"#, options: .regularExpression) != nil { return true }
        let normalized = stripped.lowercased().trimmingCharacters(in: .punctuationCharacters)
        return normalized.isEmpty || hallucinations.contains { normalized.hasPrefix($0) }
    }
}
