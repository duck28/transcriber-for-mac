import Foundation

/// Fetches captions or audio from YouTube with the `yt-dlp` command-line tool.
struct YouTubeImporter {
    enum ImportError: LocalizedError {
        case notInstalled
        case failed(String)
        case noAudio

        var errorDescription: String? {
            switch self {
            case .notInstalled:
                return "Importing from YouTube needs yt-dlp. Install it with “pip3 install -U \"yt-dlp[default]\"” in Terminal, or set its location in Settings."
            case let .failed(message):
                return "yt-dlp failed: \(message) YouTube changes often, so updating yt-dlp usually fixes this."
            case .noAudio:
                return "yt-dlp didn't download any audio."
            }
        }
    }

    struct Captions {
        let title: String
        let segments: [(offset: TimeInterval, text: String)]
    }

    /// An installed yt-dlp and its version (a release date such as "2026.08.19").
    struct Tool: Equatable {
        let url: URL
        let version: String

        /// YouTube regularly breaks older releases.
        var isOutdated: Bool {
            guard let released = Self.versionFormatter.date(from: String(version.prefix(10))) else { return false }
            return Date().timeIntervalSince(released) > 180 * 24 * 3600
        }

        /// The command that updates this copy, depending on how it was installed.
        var updateCommand: String {
            let path = url.resolvingSymlinksInPath().path
            if path.contains("/Python") || path.contains("/pipx/") { return "pip3 install -U \"yt-dlp[default]\"" }
            if path.contains("/Cellar/") || path.hasPrefix("/opt/homebrew/") { return "brew upgrade yt-dlp" }
            let writable = FileManager.default.isWritableFile(atPath: path)
            return writable ? "\(url.path) -U" : "sudo \(url.path) -U"
        }

        /// From `--js-runtimes` on, yt-dlp needs a JavaScript runtime to read YouTube pages fully.
        var supportsJavaScriptRuntimes: Bool { version >= "2025.11" }

        private static let versionFormatter: DateFormatter = {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy.MM.dd"
            return formatter
        }()
    }

    let tool: Tool

    /// The yt-dlp to use: `customPath` if set, otherwise the newest one found in common install locations.
    /// (Apps don't see the shell's PATH, so it can't simply be looked up there.)
    static func findTool(customPath: String) async -> Tool? {
        let candidates = candidateURLs(customPath: customPath)
        return await withTaskGroup(of: Tool?.self) { group in
            for url in candidates {
                group.addTask {
                    let result = try? await execute(url, ["--version"], environment: environment(for: url))
                    let version = result?.output.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    return result?.failure == nil && !version.isEmpty ? Tool(url: url, version: version) : nil
                }
            }
            var tools: [Tool] = []
            for await tool in group { if let tool { tools.append(tool) } }
            return tools.max { $0.version < $1.version }
        }
    }

    private static func candidateURLs(customPath: String) -> [URL] {
        let fileManager = FileManager.default
        let custom = (customPath.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        if !custom.isEmpty {
            return fileManager.isExecutableFile(atPath: custom) ? [URL(fileURLWithPath: custom)] : []
        }
        let home = fileManager.homeDirectoryForCurrentUser.path
        var folders = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "\(home)/.local/bin"]
        // pip installs into a folder per Python version.
        for root in ["/Library/Frameworks/Python.framework/Versions", "\(home)/Library/Python"] {
            let versions = (try? fileManager.contentsOfDirectory(atPath: root)) ?? []
            folders += versions.filter { $0 != "Current" }.map { "\(root)/\($0)/bin" }
        }
        var seen = Set<String>()
        return folders
            .map { URL(fileURLWithPath: $0).appendingPathComponent("yt-dlp") }
            .filter { fileManager.isExecutableFile(atPath: $0.path) && seen.insert($0.resolvingSymlinksInPath().path).inserted }
    }

    /// Deno is used automatically when it's on the PATH; Node or Bun have to be named explicitly.
    private static func javaScriptRuntimeArguments() -> [String] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser.path
        func firstExecutable(_ paths: [String]) -> String? { paths.first { fileManager.isExecutableFile(atPath: $0) } }

        if firstExecutable(["/opt/homebrew/bin/deno", "/usr/local/bin/deno", "\(home)/.deno/bin/deno"]) != nil { return [] }
        let nvmRoot = "\(home)/.nvm/versions/node"
        let nvmNodes = ((try? fileManager.contentsOfDirectory(atPath: nvmRoot)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { "\(nvmRoot)/\($0)/bin/node" }
        if let node = firstExecutable(["/opt/homebrew/bin/node", "/usr/local/bin/node", "\(home)/.volta/bin/node"] + nvmNodes) {
            return ["--js-runtimes", "node:\(node)"]
        }
        if let bun = firstExecutable(["/opt/homebrew/bin/bun", "/usr/local/bin/bun", "\(home)/.bun/bin/bun"]) {
            return ["--js-runtimes", "bun:\(bun)"]
        }
        return []
    }

    /// Captions in `languageCode` (uploaded ones preferred over automatic ones), or nil if the video has none.
    func captions(for video: URL, languageCode: String, in directory: URL) async throws -> Captions? {
        // Only this language and its regional variants (en-GB), not YouTube's machine translations
        // ("en-de" etc.): requesting dozens of those gets the download rate-limited (HTTP 429).
        let languages = "\(languageCode),\(languageCode)-orig,\(languageCode)-[A-Z]{2}"
        let (output, failure) = try await run([
            "--no-playlist", "--skip-download", "--no-simulate",
            "--write-subs", "--write-auto-subs", "--sub-langs", languages, "--sub-format", "json3",
            "--print", "TITLE:%(title)s",
            "-o", directory.appendingPathComponent("captions.%(ext)s").path,
            video.absoluteString,
        ])
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let captionFiles = files.filter { $0.pathExtension == "json3" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        // Prefer exactly the requested language over regional variants.
        let preferredNames = ["captions.\(languageCode).json3", "captions.\(languageCode)-orig.json3"]
        let file = preferredNames.lazy.compactMap { name in captionFiles.first { $0.lastPathComponent == name } }.first
            ?? captionFiles.first
        guard let file else {
            if let failure { throw failure }
            return nil
        }
        // A caption file arrived, so a failure on another track doesn't matter.

        let segments = try Self.parseJSON3(Data(contentsOf: file))
        guard !segments.isEmpty else { return nil }
        return Captions(title: Self.title(in: output) ?? video.absoluteString, segments: segments)
    }

    /// Downloads the audio track into `directory`. `progress` (0...1) is called on a background thread.
    func downloadAudio(from video: URL, into directory: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws -> (title: String, file: URL) {
        let (output, failure) = try await run([
            "--no-playlist", "--no-simulate", "--progress", "--newline",
            // m4a/mp4 can be read without ffmpeg.
            "-f", "bestaudio[ext=m4a]/best[ext=mp4]/bestaudio",
            "--print", "TITLE:%(title)s",
            "-o", directory.appendingPathComponent("audio.%(ext)s").path,
            video.absoluteString,
        ]) { line in
            if let percent = Self.downloadPercent(in: line) { progress(percent / 100) }
        }
        if let failure { throw failure }
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.lastPathComponent.hasPrefix("audio.") && $0.pathExtension != "part" }) else {
            throw ImportError.noAudio
        }
        return (Self.title(in: output) ?? video.absoluteString, file)
    }

    // MARK: - Parsing

    private struct JSON3: Decodable {
        struct Event: Decodable {
            let tStartMs: Double?
            let segs: [Segment]?
        }

        struct Segment: Decodable {
            let utf8: String?
        }

        let events: [Event]?
    }

    /// Joins YouTube's short caption lines into paragraphs of a few sentences.
    static func parseJSON3(_ data: Data) throws -> [(offset: TimeInterval, text: String)] {
        let events = try JSONDecoder().decode(JSON3.self, from: data).events ?? []
        var paragraphs: [(offset: TimeInterval, text: String)] = []
        var start: TimeInterval?
        var words: [Substring] = []

        func flush() {
            if let start, !words.isEmpty { paragraphs.append((start, words.joined(separator: " "))) }
            start = nil
            words = []
        }

        for event in events {
            let line = (event.segs ?? []).compactMap(\.utf8).joined()
            let lineWords = line.split(whereSeparator: \.isWhitespace)
            guard !lineWords.isEmpty else { continue }
            let time = (event.tStartMs ?? 0) / 1000
            if let start {
                let length = time - start
                let endsSentence = words.last.map { ".?!".contains($0.last ?? " ") } ?? false
                if length >= 30 || (length >= 10 && endsSentence) { flush() }
            }
            if start == nil { start = time }
            words += lineWords
        }
        flush()
        return paragraphs
    }

    private static func title(in output: String) -> String? {
        output.split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("TITLE:") }
            .map { String($0.dropFirst("TITLE:".count)) }
    }

    private static func downloadPercent(in line: String) -> Double? {
        guard line.hasPrefix("[download]"),
              let range = line.range(of: #"[0-9.]+(?=%)"#, options: .regularExpression) else { return nil }
        return Double(line[range])
    }

    // MARK: - Process

    /// Runs yt-dlp. Returns its standard output, and the error it reported if it failed.
    /// Cancelling the task terminates the process.
    private func run(_ arguments: [String],
                     onLine: (@Sendable (String) -> Void)? = nil) async throws -> (output: String, failure: ImportError?) {
        let runtime = tool.supportsJavaScriptRuntimes ? Self.javaScriptRuntimeArguments() : []
        return try await Self.execute(tool.url, runtime + arguments, environment: Self.environment(for: tool.url), onLine: onLine)
    }

    /// yt-dlp looks up ffmpeg and Deno on the PATH, which apps launched from Finder lack.
    private static func environment(for executable: URL) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let folders = [executable.deletingLastPathComponent().path, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
                       "\(home)/.deno/bin"]
        environment["PATH"] = (folders + [environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")
        return environment
    }

    private static func execute(_ executable: URL, _ arguments: [String], environment: [String: String],
                                onLine: (@Sendable (String) -> Void)? = nil) async throws -> (output: String, failure: ImportError?) {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment

        let output = OutputCollector(onLine: onLine)
        let errors = OutputCollector(onLine: onLine)
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        for (pipe, collector) in [(outputPipe, output), (errorPipe, errors)] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil } else { collector.append(data) }
            }
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { _ in continuation.resume() }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        for (pipe, collector) in [(outputPipe, output), (errorPipe, errors)] {
            pipe.fileHandleForReading.readabilityHandler = nil
            collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
        }
        try Task.checkCancellation()
        guard process.terminationStatus != 0 else { return (output.text, nil) }
        let lines = errors.text.split(whereSeparator: \.isNewline)
        let message = lines.last { $0.hasPrefix("ERROR:") }.map { $0.dropFirst("ERROR:".count) }
            ?? lines.last
            ?? "exit status \(process.terminationStatus)."
        return (output.text, ImportError.failed(message.trimmingCharacters(in: .whitespaces)))
    }
}

/// Collects a process's output and reports complete lines (yt-dlp ends progress lines with \r or \n).
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var partialLine = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var text: String { lock.withLock { String(decoding: data, as: UTF8.self) } }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines = lock.withLock { () -> [String] in
            data.append(chunk)
            var parts = (partialLine + String(decoding: chunk, as: UTF8.self))
                .components(separatedBy: CharacterSet(charactersIn: "\r\n"))
            partialLine = parts.removeLast()
            return parts.filter { !$0.isEmpty }
        }
        lines.forEach { onLine?($0) }
    }
}
