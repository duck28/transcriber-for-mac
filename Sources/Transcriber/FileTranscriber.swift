import AVFoundation
import Speech

/// Transcribes a recorded audio or video file (voice memos, downloads, …) on this Mac.
///
/// The audio is fed to the recognizer in chunks of `minChunk`–`maxChunk` seconds, each cut at the quietest
/// moment in that window so words aren't split. Every chunk becomes one transcript segment.
/// With Whisper the chunks stay under its 30-second window.
final class FileTranscriber {
    enum FileError: LocalizedError {
        case unreadable(String)

        var errorDescription: String? {
            switch self {
            case let .unreadable(name): return "“\(name)” doesn't contain audio Transcriber can read."
            }
        }
    }

    private enum Recognizer {
        case apple(SFSpeechRecognizer)
        case whisper(WhisperEngine, language: String?, swissSpelling: Bool, parameters: WhisperParameters)
    }

    private let recognizer: Recognizer
    private let blockDuration: TimeInterval = 0.25
    private let minChunk: TimeInterval
    private let maxChunk: TimeInterval

    init(locale: Locale) throws {
        recognizer = .apple(try LiveTranscriber.makeRecognizer(locale: locale))
        (minChunk, maxChunk) = (20, 45)
    }

    /// Transcribes with Whisper; the engine must already have a model prepared.
    init(whisper engine: WhisperEngine, locale: Locale, parameters: WhisperParameters = .standard) {
        recognizer = .whisper(engine, language: WhisperEngine.languageCode(for: locale),
                              swissSpelling: locale.region?.identifier == "CH", parameters: parameters)
        (minChunk, maxChunk) = (15, 28)
    }

    /// One recognized chunk of the file. Times are seconds from the beginning of the file.
    struct Passage {
        let start: TimeInterval
        let text: String
        let words: [TimedWord]
    }

    func transcribe(_ url: URL,
                    onProgress: @escaping @MainActor (Double) -> Void,
                    onPassage: @escaping @MainActor (Passage) -> Void) async throws {
        let (file, temporaryCopy) = try await Self.openAudio(url)
        defer { if let temporaryCopy { try? FileManager.default.removeItem(at: temporaryCopy) } }

        let format = file.processingFormat
        let blockFrames = AVAudioFrameCount(format.sampleRate * blockDuration)
        let converter = BufferConverter(outputFormat: LiveTranscriber.speechFormat)
        var blocks: [AVAudioPCMBuffer] = []
        var chunkStart: TimeInterval = 0
        var succeeded = 0
        var lastError: Error?

        func recognizeChunk(_ chunk: [AVAudioPCMBuffer]) async throws {
            do {
                if let result = try await recognize(chunk) {
                    let words = result.words.map {
                        TimedWord(text: $0.text, start: chunkStart + $0.start, end: chunkStart + $0.end)
                    }
                    await onPassage(Passage(start: words.first?.start ?? chunkStart, text: result.text, words: words))
                }
                succeeded += 1
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
            }
            chunkStart += Self.duration(of: chunk)
        }

        while file.framePosition < file.length {
            try Task.checkCancellation()
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { break }
            try file.read(into: buffer, frameCount: blockFrames)
            guard buffer.frameLength > 0 else { break }
            if let converted = converter.convert(buffer) { blocks.append(converted) }

            if Self.duration(of: blocks) >= maxChunk {
                let cut = quietestCut(in: blocks)
                let chunk = Array(blocks[...cut])
                blocks.removeFirst(cut + 1)
                try await recognizeChunk(chunk)
                await onProgress(Double(file.framePosition) / Double(max(file.length, 1)))
            }
        }
        if !blocks.isEmpty { try await recognizeChunk(blocks) }
        await onProgress(1)
        // A single unreadable chunk is skipped, but if nothing worked at all, say why.
        if succeeded == 0, let lastError { throw lastError }
    }

    /// Index of the quietest block that still leaves the chunk at least `minChunk` long.
    private func quietestCut(in blocks: [AVAudioPCMBuffer]) -> Int {
        var elapsed: TimeInterval = 0
        var best = blocks.count - 1
        var bestLevel = Float.greatestFiniteMagnitude
        for (index, block) in blocks.enumerated() {
            elapsed += Self.duration(of: [block])
            guard elapsed >= minChunk else { continue }
            let level = BufferConverter.rms(of: block)
            if level < bestLevel {
                bestLevel = level
                best = index
            }
        }
        return best
    }

    /// Recognizes one chunk. Returns nil if it contains no speech.
    private func recognize(_ buffers: [AVAudioPCMBuffer]) async throws -> (text: String, words: [TimedWord])? {
        switch recognizer {
        case let .apple(recognizer):
            return try await recognize(buffers, with: recognizer)
        case let .whisper(engine, language, swissSpelling, parameters):
            let samples = buffers.flatMap { buffer in
                UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength))
            }
            try Task.checkCancellation()
            let result = try await engine.transcribe(samples, language: language, swissSpelling: swissSpelling,
                                                     wordTimestamps: true, parameters: parameters)
            return result.map { ($0.text, $0.words) }
        }
    }

    private func recognize(_ buffers: [AVAudioPCMBuffer],
                           with recognizer: SFSpeechRecognizer) async throws -> (text: String, words: [TimedWord])? {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        request.addsPunctuation = true
        request.taskHint = .dictation

        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var resumed = false
                // The handler runs on the recognizer's queue (main), so `resumed` needs no lock.
                box.task = recognizer.recognitionTask(with: request) { result, error in
                    guard !resumed else { return }
                    if let result, result.isFinal {
                        resumed = true
                        let transcription = result.bestTranscription
                        let text = transcription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                        continuation.resume(returning: text.isEmpty ? nil : (text, Self.words(in: transcription)))
                    } else if let error {
                        resumed = true
                        // 1110 = "No speech detected": a silent chunk, not a failure.
                        if (error as NSError).code == 1110 {
                            continuation.resume(returning: nil)
                        } else {
                            continuation.resume(throwing: error)
                        }
                    }
                }
                buffers.forEach(request.append)
                request.endAudio()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// The recognized words with their timing (relative to the start of the request).
    /// The timed segments lack punctuation, so it is taken from the formatted text where the words line up.
    static func words(in transcription: SFTranscription) -> [TimedWord] {
        let tokens = transcription.formattedString.split(whereSeparator: \.isWhitespace).map(String.init)
        var nextToken = 0
        return transcription.segments.map { segment in
            var text = segment.substring
            let key = normalized(segment.substring)
            for index in nextToken..<min(nextToken + 3, tokens.count) where normalized(tokens[index]) == key {
                text = tokens[index]
                nextToken = index + 1
                break
            }
            return TimedWord(text: text, start: segment.timestamp, end: segment.timestamp + segment.duration)
        }
    }

    private static func normalized(_ word: String) -> String {
        String(word.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
    }

    private static func duration(of blocks: [AVAudioPCMBuffer]) -> TimeInterval {
        blocks.reduce(0) { $0 + Double($1.frameLength) } / LiveTranscriber.speechFormat.sampleRate
    }

    /// Opens `url` for reading. Formats `AVAudioFile` can't read directly (such as videos) are first
    /// exported to a temporary `.m4a`, which the caller deletes when done.
    private static func openAudio(_ url: URL) async throws -> (AVAudioFile, temporaryCopy: URL?) {
        if let file = try? AVAudioFile(forReading: url) { return (file, nil) }

        let asset = AVURLAsset(url: url)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw FileError.unreadable(url.lastPathComponent)
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        session.outputURL = output
        session.outputFileType = .m4a
        await session.export()
        guard session.status == .completed, let file = try? AVAudioFile(forReading: output) else {
            try? FileManager.default.removeItem(at: output)
            throw FileError.unreadable(url.lastPathComponent)
        }
        return (file, output)
    }
}

/// Lets a cancellation handler reach a recognition task created inside a continuation.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var _task: SFSpeechRecognitionTask?

    var task: SFSpeechRecognitionTask? {
        get { lock.withLock { _task } }
        set {
            let cancelNow = lock.withLock { () -> Bool in
                _task = newValue
                return cancelled
            }
            if cancelNow { newValue?.cancel() }
        }
    }

    func cancel() {
        let task = lock.withLock { () -> SFSpeechRecognitionTask? in
            cancelled = true
            return _task
        }
        task?.cancel()
    }
}
