import Foundation

/// A recognized word and when it was spoken, in seconds.
struct TimedWord: Equatable {
    let text: String
    let start: TimeInterval
    let end: TimeInterval
}

/// One subtitle: up to two lines of text shown from `start` to `end` (seconds).
struct SubtitleCue: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var lines: [String]

    var text: String { lines.joined(separator: " ") }
}

/// How much text a subtitle may hold.
enum SubtitleStyle: String, CaseIterable, Identifiable {
    case standard
    case shortForm

    var id: Self { self }

    var title: String {
        switch self {
        case .standard: return "Standard: 2 lines of up to 42 characters"
        case .shortForm: return "Short-form video: 1 line of up to 32 characters"
        }
    }

    var maxCharactersPerLine: Int { self == .standard ? 42 : 32 }
    var maxLines: Int { self == .standard ? 2 : 1 }
    var maxDuration: TimeInterval { self == .standard ? 7 : 3.5 }
}

enum SubtitleFormat: CaseIterable, Identifiable {
    case srt, webVTT, finalCutPro

    var id: Self { self }

    var fileExtension: String {
        switch self {
        case .srt: return "srt"
        case .webVTT: return "vtt"
        case .finalCutPro: return "fcpxml"
        }
    }

    var menuTitle: String {
        switch self {
        case .srt: return "SubRip (.srt) – DaVinci Resolve, Premiere Pro…"
        case .webVTT: return "WebVTT (.vtt)…"
        case .finalCutPro: return "Final Cut Pro Project (.fcpxml)…"
        }
    }
}

/// Frame rates offered for Final Cut Pro projects. Caption times are snapped to frames.
enum VideoFrameRate: String, CaseIterable, Identifiable {
    case fps23_976 = "23.976"
    case fps24 = "24"
    case fps25 = "25"
    case fps29_97 = "29.97"
    case fps30 = "30"
    case fps50 = "50"
    case fps59_94 = "59.94"
    case fps60 = "60"

    var id: Self { self }
    var title: String { "\(rawValue) fps" }

    /// The length of one frame as a fraction of a second.
    var frameDuration: (value: Int, timescale: Int) {
        switch self {
        case .fps23_976: return (1001, 24000)
        case .fps24: return (100, 2400)
        case .fps25: return (100, 2500)
        case .fps29_97: return (1001, 30000)
        case .fps30: return (100, 3000)
        case .fps50: return (100, 5000)
        case .fps59_94: return (1001, 60000)
        case .fps60: return (100, 6000)
        }
    }

    fileprivate var formatName: String {
        switch self {
        case .fps23_976: return "FFVideoFormat1080p2398"
        case .fps29_97: return "FFVideoFormat1080p2997"
        case .fps59_94: return "FFVideoFormat1080p5994"
        default: return "FFVideoFormat1080p\(rawValue)"
        }
    }

    fileprivate var isDropFrame: Bool { self == .fps29_97 || self == .fps59_94 }
}

// MARK: - Building cues

enum SubtitleBuilder {
    /// Every subtitle stays up at least this long, if the next one allows it.
    static let minDuration: TimeInterval = 1
    /// A pause this long in speech starts a new subtitle.
    static let pauseBreak: TimeInterval = 0.6
    /// Subtitles stay up this much longer than the last word, if the next one allows it.
    static let hold: TimeInterval = 0.4
    /// The smallest gap left between two subtitles.
    static let minGap: TimeInterval = 0.05

    /// Groups words into subtitles, starting a new one at the end of a sentence, at pauses,
    /// and whenever the text or duration would exceed what `style` allows.
    static func cues(from words: [TimedWord], style: SubtitleStyle) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [TimedWord] = []

        func close() {
            guard let first = current.first, let last = current.last else { return }
            let text = current.map(\.text).joined(separator: " ")
            cues.append(SubtitleCue(start: first.start, end: max(last.end, first.start),
                                    lines: layout(text, style: style) ?? [text]))
            current = []
        }

        for word in words {
            if let first = current.first, let last = current.last {
                let text = (current + [word]).map(\.text).joined(separator: " ")
                if word.start - last.end >= pauseBreak
                    || word.end - first.start > style.maxDuration
                    || layout(text, style: style) == nil {
                    close()
                }
            }
            current.append(word)

            let length = current.map(\.text).joined(separator: " ").count
            let capacity = style.maxCharactersPerLine * style.maxLines
            if let mark = word.text.last, ".?!…".contains(mark) {
                close()
            } else if word.text.hasSuffix(","), length * 10 >= capacity * 6 {
                close()
            }
        }
        close()
        return adjustTiming(cues)
    }

    /// Splits `text` into at most `style.maxLines` lines that each fit, with line lengths as even as possible.
    /// Returns nil if the text doesn't fit.
    static func layout(_ text: String, style: SubtitleStyle) -> [String]? {
        let limit = style.maxCharactersPerLine
        if text.count <= limit { return [text] }
        guard style.maxLines >= 2 else { return nil }

        let words = text.split(separator: " ").map(String.init)
        var best: (lines: [String], score: Int)?
        for split in 1..<max(words.count, 1) {
            let first = words[..<split].joined(separator: " ")
            let second = words[split...].joined(separator: " ")
            guard first.count <= limit, second.count <= limit else { continue }
            var score = abs(first.count - second.count)
            // Breaking after punctuation reads more naturally.
            if let mark = first.last, ",;:.?!".contains(mark) { score -= 10 }
            if best == nil || score < best!.score { best = ([first, second], score) }
        }
        return best?.lines
    }

    /// Lengthens subtitles a little past their last word, without overlapping the next one.
    private static func adjustTiming(_ cues: [SubtitleCue]) -> [SubtitleCue] {
        var result = cues
        for index in result.indices {
            let nextStart = index + 1 < result.count ? result[index + 1].start - minGap : .infinity
            let wanted = max(result[index].end + hold, result[index].start + minDuration)
            result[index].end = min(wanted, nextStart)
            if result[index].end <= result[index].start {
                result[index].end = result[index].start + 0.1
            }
        }
        return result
    }
}

// MARK: - Writing files

enum SubtitleWriter {
    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, ",")) --> \(timestamp(cue.end, ","))\n\(cue.lines.joined(separator: "\n"))\n"
        }
        .joined(separator: "\n")
    }

    static func webVTT(_ cues: [SubtitleCue]) -> String {
        "WEBVTT\n\n" + cues.map { cue in
            "\(timestamp(cue.start, ".")) --> \(timestamp(cue.end, "."))\n\(cue.lines.joined(separator: "\n"))\n"
        }
        .joined(separator: "\n")
    }

    /// Details of the voiceover file that the Final Cut Pro project references.
    struct AudioInfo {
        let url: URL
        let duration: TimeInterval
        let channels: Int
        let sampleRate: Int
    }

    /// A Final Cut Pro project (FCPXML 1.10, Final Cut Pro 10.6 or later) with the voiceover on the timeline
    /// and the subtitles as captions attached to it.
    static func finalCutPro(_ cues: [SubtitleCue], audio: AudioInfo, title: String,
                            languageCode: String, frameRate: VideoFrameRate) -> String {
        let (value, timescale) = frameRate.frameDuration
        let frameSeconds = Double(value) / Double(timescale)
        func frames(_ seconds: TimeInterval) -> Int { Int((seconds / frameSeconds).rounded()) }
        func time(_ frames: Int) -> String { frames == 0 ? "0s" : "\(frames * value)/\(timescale)s" }

        let lastCueEnd = cues.last.map { frames($0.end) } ?? 0
        let total = max(Int((audio.duration / frameSeconds).rounded(.up)), lastCueEnd, 1)
        let starts = cues.map { frames($0.start) }
        let role = "SRT?captionFormat=SRT.\(languageCode)"

        var captions: [String] = []
        for (index, cue) in cues.enumerated() {
            let start = starts[index]
            let limit = index + 1 < starts.count ? starts[index + 1] : total
            let end = min(max(frames(cue.end), start + 1), max(limit, start + 1))
            let text = escape(cue.lines.joined(separator: "\n"))
            let name = escape(String(cue.text.prefix(40)))
            captions.append("""
                                        <caption lane="1" offset="\(time(start))" name="\(name)" duration="\(time(end - start))" role="\(role)">
                                            <text placement="bottom">
                                                <text-style ref="ts\(index + 1)">\(text)</text-style>
                                            </text>
                                            <text-style-def id="ts\(index + 1)">
                                                <text-style font=".AppleSystemUIFont" fontSize="13" fontFace="Regular" fontColor="1 1 1 1" backgroundColor="0 0 0 1"/>
                                            </text-style-def>
                                        </caption>
            """)
        }

        let clipName = escape(audio.url.deletingPathExtension().lastPathComponent)
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE fcpxml>
        <fcpxml version="1.10">
            <resources>
                <format id="r1" name="\(frameRate.formatName)" frameDuration="\(value)/\(timescale)s" width="1920" height="1080"/>
                <asset id="r2" name="\(clipName)" start="0s" duration="\(time(total))" hasAudio="1" audioSources="1" audioChannels="\(audio.channels)" audioRate="\(audio.sampleRate)">
                    <media-rep kind="original-media" src="\(escape(audio.url.absoluteString))"/>
                </asset>
            </resources>
            <library>
                <event name="Transcriber">
                    <project name="\(escape(title))">
                        <sequence format="r1" duration="\(time(total))" tcStart="0s" tcFormat="\(frameRate.isDropFrame ? "DF" : "NDF")" audioLayout="stereo" audioRate="48k">
                            <spine>
                                <asset-clip ref="r2" offset="0s" name="\(clipName)" duration="\(time(total))" audioRole="dialogue">
        \(captions.joined(separator: "\n"))
                                </asset-clip>
                            </spine>
                        </sequence>
                    </project>
                </event>
            </library>
        </fcpxml>

        """
    }

    private static func timestamp(_ seconds: TimeInterval, _ separator: String) -> String {
        let milliseconds = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d",
                      milliseconds / 3_600_000, milliseconds / 60_000 % 60, milliseconds / 1000 % 60,
                      separator, milliseconds % 1000)
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
