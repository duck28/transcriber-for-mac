import AVFoundation
import Speech

/// Streams audio into on-device `SFSpeechRecognizer` tasks.
///
/// Speech is split into segments: when the recognized text stops changing for `pauseInterval`
/// (or a segment runs longer than `maxSegmentDuration`), the current request is closed, its final
/// text is emitted through `onFinal`, and a fresh request takes over seamlessly.
final class LiveTranscriber {
    enum TranscriberError: LocalizedError {
        case notAuthorized
        case unavailable(Locale)
        case noOnDeviceModel(Locale)

        var errorDescription: String? {
            switch self {
            case .notAuthorized:
                return "Speech recognition is not allowed. Enable it in System Settings › Privacy & Security › Speech Recognition."
            case let .unavailable(locale):
                return "Speech recognition for \(locale.identifier) is currently unavailable."
            case let .noOnDeviceModel(locale):
                return "No on-device speech model for \(locale.identifier). Enable Dictation for this language in System Settings › Keyboard to download it."
            }
        }
    }

    var onPartial: ((String) -> Void)?
    var onFinal: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    /// What the recognizer is fed: 16 kHz mono float.
    static let speechFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let recognizer: SFSpeechRecognizer
    private let converter = BufferConverter(outputFormat: LiveTranscriber.speechFormat)

    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var segmentID = 0
    private var segmentStart = Date()
    private var lastTextChange = Date()
    private var latestText = ""
    private var rotationTimer: Timer?
    private var onDrained: (() -> Void)?

    private let pauseInterval: TimeInterval = 1.6
    private let maxSegmentDuration: TimeInterval = 50

    init(locale: Locale) throws {
        recognizer = try Self.makeRecognizer(locale: locale)
    }

    /// An on-device recognizer for `locale`, or an error explaining why there is none.
    static func makeRecognizer(locale: Locale) throws -> SFSpeechRecognizer {
        guard let recognizer = SFSpeechRecognizer(locale: locale) else { throw TranscriberError.unavailable(locale) }
        guard recognizer.supportsOnDeviceRecognition else { throw TranscriberError.noOnDeviceModel(locale) }
        guard recognizer.isAvailable else { throw TranscriberError.unavailable(locale) }
        return recognizer
    }

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
    }

    /// Every language speech recognition supports, sorted by name, and which of them can already be
    /// transcribed fully offline on this Mac. The others need their Dictation model downloaded first.
    static func availableLocales() -> (all: [Locale], installed: Set<String>) {
        var installed: Set<String> = []
        let all = Array(SFSpeechRecognizer.supportedLocales())
        for locale in all where SFSpeechRecognizer(locale: locale)?.supportsOnDeviceRecognition == true {
            installed.insert(locale.identifier)
        }
        let names = Dictionary(all.map { ($0.identifier, displayName(for: $0)) }, uniquingKeysWith: { first, _ in first })
        return (all.sorted { names[$0.identifier]!.localizedStandardCompare(names[$1.identifier]!) == .orderedAscending },
                installed)
    }

    /// The locale's name in the user's language, such as "German (Switzerland)".
    static func displayName(for locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    /// Call on the main thread.
    func start() {
        startSegment()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.rotateIfNeeded()
        }
    }

    /// Call on the main thread. The last segment is flushed through `onFinal`, then `completion` runs.
    /// The transcriber keeps itself alive until then (at most a few seconds).
    func stop(completion: (() -> Void)? = nil) {
        rotationTimer?.invalidate()
        rotationTimer = nil
        finishCurrentSegment()
        lock.withLock { request = nil }
        onDrained = completion
        if pendingSegments.isEmpty {
            drain()
        } else {
            // Don't wait forever for final results; fall back to the last preview text.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [self] in drain() }
        }
    }

    /// Safe to call from the audio thread; the buffer is converted (and copied) synchronously.
    func append(_ buffer: AVAudioPCMBuffer) {
        guard let converted = converter.convert(buffer) else { return }
        onLevel?(BufferConverter.rms(of: converted))
        lock.withLock { request }?.append(converted)
    }

    // MARK: - Segments

    private func startSegment() {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        request.taskHint = .dictation

        segmentID += 1
        let id = segmentID
        segmentStart = Date()
        lastTextChange = Date()
        latestText = ""

        let task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString ?? ""
            let isFinal = result?.isFinal ?? false
            DispatchQueue.main.async {
                self?.handle(text: text, isFinal: isFinal, failed: error != nil, segment: id)
            }
        }
        lock.withLock {
            self.request = request
            self.task = task
        }
    }

    private func handle(text: String, isFinal: Bool, failed: Bool, segment: Int) {
        if segment == segmentID {
            // Live segment: show progress. If the task ends on its own (e.g. long silence), start a new one.
            if !text.isEmpty, text != latestText {
                latestText = text
                lastTextChange = Date()
                onPartial?(text)
            }
            guard isFinal || failed else { return }
            emitFinal(text.isEmpty ? latestText : text)
            latestText = ""
            onPartial?("")
            lock.withLock { request = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.rotationTimer != nil, self.segmentID == segment else { return }
                self.startSegment()
            }
        } else if isFinal || failed {
            // A segment we closed ourselves, delivering its final text (at most once).
            guard let fallback = pendingSegments.removeValue(forKey: segment) else { return }
            emitFinal(text.isEmpty ? fallback : text)
            if rotationTimer == nil, pendingSegments.isEmpty { drain() }
        }
    }

    private func rotateIfNeeded() {
        let now = Date()
        let paused = !latestText.isEmpty && now.timeIntervalSince(lastTextChange) >= pauseInterval
        let tooLong = now.timeIntervalSince(segmentStart) >= maxSegmentDuration
        guard paused || tooLong else { return }
        finishCurrentSegment()
        startSegment()
    }

    private func finishCurrentSegment() {
        let closing = lock.withLock { () -> SFSpeechAudioBufferRecognitionRequest? in
            defer { request = nil }
            return request
        }
        guard let closing else { return }
        // The final text arrives later via `handle(... segment:)`; keep the preview as a fallback.
        pendingSegments[segmentID] = latestText
        segmentID += 1
        closing.endAudio()
        latestText = ""
        onPartial?("")
    }

    /// Last known text of closed segments, used if their final result comes back empty.
    private var pendingSegments: [Int: String] = [:]

    /// Emits whatever closed segments are still waiting for a final result, then reports that stopping is done.
    private func drain() {
        for segment in pendingSegments.keys.sorted() {
            emitFinal(pendingSegments[segment] ?? "")
        }
        pendingSegments.removeAll()
        let completion = onDrained
        onDrained = nil
        completion?()
    }

    private func emitFinal(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { onFinal?(trimmed) }
    }
}
