import AVFoundation

/// Saves captured audio as an AAC `.m4a` file. Encoding and disk writes happen on a background queue.
final class AudioRecorder {
    let url: URL
    /// Called on the main queue, at most once, if the file can't be written.
    var onError: ((Error) -> Void)?

    private let queue = DispatchQueue(label: "Transcriber.AudioRecorder")
    private var converter: BufferConverter?
    // Only touched on `queue`.
    private var file: AVAudioFile?
    private var finished = false
    private var failed = false

    init(url: URL) {
        self.url = url
    }

    /// Call from the capture thread. The buffer is copied before this returns.
    func append(_ buffer: AVAudioPCMBuffer) {
        if converter == nil {
            // AAC tops out at 48 kHz; more than two channels are downmixed to stereo.
            let rate = min(buffer.format.sampleRate, 48_000)
            let channels = min(buffer.format.channelCount, 2)
            guard let format = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels) else { return }
            converter = BufferConverter(outputFormat: format)
        }
        guard let copy = converter?.convert(buffer) else { return }
        queue.async { [self] in write(copy) }
    }

    /// Writes the remaining audio and closes the file.
    func finish() {
        queue.sync {
            finished = true
            file = nil
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !finished, !failed else { return }
        do {
            if file == nil {
                let settings: [String: Any] = [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: buffer.format.sampleRate,
                    AVNumberOfChannelsKey: buffer.format.channelCount,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
                ]
                file = try AVAudioFile(forWriting: url, settings: settings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            }
            try file?.write(from: buffer)
        } catch {
            failed = true
            file = nil
            DispatchQueue.main.async { [onError] in onError?(error) }
        }
    }
}
