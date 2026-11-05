import AVFoundation

/// What live transcription needs from a speech recognizer; see `LiveTranscriber` and `WhisperLiveTranscriber`.
protocol SpeechTranscribing: AnyObject {
    var onPartial: ((String) -> Void)? { get set }
    var onFinal: ((String) -> Void)? { get set }
    var onLevel: ((Float) -> Void)? { get set }
    /// Call on the main thread.
    func start()
    /// Call on the main thread. The last segment is flushed through `onFinal`, then `completion` runs.
    func stop(completion: (() -> Void)?)
    /// Safe to call from the audio thread.
    func append(_ buffer: AVAudioPCMBuffer)
}

extension LiveTranscriber: SpeechTranscribing {}

/// Live transcription with Whisper, which recognizes whole stretches of audio rather than a stream.
///
/// While someone talks, the audio of the current phrase is recognized over and over and shown through
/// `onPartial`. When they pause for `pauseInterval` (or the phrase reaches `maxSegmentDuration`), the phrase
/// is emitted through `onFinal`, reusing the last preview if it already covered all of the speech.
/// The timing comes from `WhisperParameters` (Settings › Expert Options).
final class WhisperLiveTranscriber: SpeechTranscribing {
    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    private let engine: WhisperEngine
    private let language: String?
    private let swissSpelling: Bool
    private let parameters: WhisperParameters
    private let converter = BufferConverter(outputFormat: LiveTranscriber.speechFormat)
    private static let sampleRate = LiveTranscriber.speechFormat.sampleRate

    private let lock = NSLock()
    /// Audio of the current phrase (guarded by `lock`, like the other audio state below).
    private var samples: [Float] = []
    /// Where each appended block ends in `samples`, and how loud it was.
    private var blocks: [(end: Int, level: Float)] = []
    private var silentSamples = 0
    private var heardSpeech = false

    /// Phrases waiting to be recognized.
    private var finished: [[Float]] = []
    private var worker: Task<Void, Never>?
    private var tickTimer: Timer?
    private var onDrained: (() -> Void)?
    /// Counts phrases, so results for a phrase that has since been cut are recognized as stale.
    private var phrase = 0
    /// The newest preview of the current phrase: how many samples it covered and what it said.
    private var preview: (phrase: Int, length: Int, text: String?)?
    private var previewRunning = false
    /// Tells a running preview to stop decoding because its phrase is over.
    private let cancelPreview = Flag()

    private let pauseInterval: TimeInterval
    private let maxSegmentDuration: TimeInterval
    /// When a phrase gets too long, it's cut at the quietest moment of its last few seconds.
    private let cutWindow: TimeInterval = 4
    private let previewStep: TimeInterval = 1
    /// Below this level a block counts as silence.
    private let speechLevel: Float

    init(engine: WhisperEngine = .shared, locale: Locale, parameters: WhisperParameters = .standard) {
        self.engine = engine
        language = WhisperEngine.languageCode(for: locale)
        swissSpelling = locale.region?.identifier == "CH"
        self.parameters = parameters
        pauseInterval = parameters.pauseInterval
        maxSegmentDuration = parameters.maxPhraseDuration
        speechLevel = parameters.speechLevel
    }

    func start() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
    }

    func stop(completion: (() -> Void)? = nil) {
        tickTimer?.invalidate()
        tickTimer = nil
        cutPhrase(at: nil)
        onDrained = completion
        work()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer), let data = converted.floatChannelData?[0] else { return }
        let level = BufferConverter.rms(of: converted)
        onLevel?(level)
        let count = Int(converted.frameLength)
        lock.withLock {
            if level >= speechLevel {
                heardSpeech = true
                silentSamples = 0
            } else {
                silentSamples += count
            }
            samples.append(contentsOf: UnsafeBufferPointer(start: data, count: count))
            blocks.append((samples.count, level))
            if !heardSpeech, samples.count > Int(Self.sampleRate) {
                // Nothing said yet: keep only the last half second, so the first word isn't clipped.
                dropFirst(samples.count - Int(Self.sampleRate / 2))
            }
        }
    }

    // MARK: - Phrases

    private func tick() {
        let (length, silence, speech) = lock.withLock { (samples.count, silentSamples, heardSpeech) }
        if speech, Double(silence) / Self.sampleRate >= pauseInterval {
            cutPhrase(at: nil)
        } else if Double(length) / Self.sampleRate >= maxSegmentDuration {
            cutPhrase(at: quietestCut())
        }
        work()
    }

    /// Where to split an overlong phrase: after the quietest block of its last `cutWindow` seconds. Call on main.
    private func quietestCut() -> Int {
        lock.withLock {
            let earliest = samples.count - Int(cutWindow * Self.sampleRate)
            let quietest = blocks.filter { $0.end >= earliest }.min { $0.level < $1.level }
            return quietest?.end ?? samples.count
        }
    }

    /// Ends the current phrase after `cut` samples (all of them if nil); the rest starts the next phrase.
    private func cutPhrase(at cut: Int?) {
        let (audio, speechEnd) = lock.withLock { () -> ([Float]?, Int) in
            let end = min(cut ?? samples.count, samples.count)
            let audio = heardSpeech ? Array(samples[..<end]) : nil
            let speechEnd = cut == nil ? samples.count - silentSamples : end
            dropFirst(end)
            if samples.isEmpty {
                heardSpeech = false
                silentSamples = 0
            } else {
                silentSamples = min(silentSamples, samples.count)
            }
            return (audio, speechEnd)
        }
        defer {
            phrase += 1
            preview = nil
            if previewRunning { cancelPreview.set(true) }
            onPartial?("")
        }
        guard let audio else { return }
        if cut == nil, let preview, preview.phrase == phrase, preview.length >= speechEnd {
            // The preview already heard everything that was said; no need to recognize it again.
            // (Not for a split phrase: the preview may contain words from the part that goes on.)
            if let text = preview.text { onFinal?(text) }
        } else {
            finished.append(audio)
        }
    }

    /// Removes recognized audio from the front of the phrase. Call with `lock` held.
    private func dropFirst(_ count: Int) {
        guard count > 0 else { return }
        samples.removeFirst(count)
        blocks = blocks.compactMap { $0.end > count ? ($0.end - count, $0.level) : nil }
    }

    /// Recognizes the next finished phrase, or else refreshes the preview. One recognition runs at a time.
    private func work() {
        guard worker == nil else { return }
        if !finished.isEmpty {
            let audio = finished.removeFirst()
            run(audio, stoppable: false) { [weak self] text in
                guard let self, let text else { return }
                onFinal?(text)
            }
        } else if tickTimer == nil {
            let completion = onDrained
            onDrained = nil
            completion?()
        } else {
            let audio = lock.withLock { heardSpeech ? samples : [] }
            let previewed = preview?.length ?? 0
            guard !audio.isEmpty, Double(audio.count - previewed) / Self.sampleRate >= previewStep else { return }
            let current = phrase
            previewRunning = true
            cancelPreview.set(false)
            run(audio, stoppable: true) { [weak self] text in
                guard let self else { return }
                previewRunning = false
                // A preview that finishes after its phrase was cut is stale.
                guard current == phrase else { return }
                preview = (current, audio.count, text)
                if let text { onPartial?(text) }
            }
        }
    }

    private func run(_ audio: [Float], stoppable: Bool, then handle: @escaping (String?) -> Void) {
        let (engine, language, swissSpelling, parameters, flag) = (engine, language, swissSpelling, parameters, cancelPreview)
        var shouldStop: (@Sendable () -> Bool)?
        if stoppable { shouldStop = { flag.isSet } }
        worker = Task { @MainActor [weak self] in
            let text = try? await engine.transcribe(audio, language: language, swissSpelling: swissSpelling,
                                                    wordTimestamps: false, parameters: parameters,
                                                    shouldStop: shouldStop)?.text
            guard let self else { return }
            self.worker = nil
            handle(text)
            self.work()
        }
    }
}

/// A thread-safe boolean.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }

    func set(_ newValue: Bool) { lock.withLock { value = newValue } }
}
