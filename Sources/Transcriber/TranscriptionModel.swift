import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

struct TranscriptSegment: Identifiable {
    let id = UUID()
    /// Seconds since the live transcript started, or since the beginning of the imported media.
    let offset: TimeInterval
    let text: String
    /// When the segment ends; only known for subtitle cues.
    var end: TimeInterval? = nil
}

enum TranscriptSource: Equatable {
    case live
    case file(URL)
    case youtube(URL)
    /// A voiceover turned into subtitles (narrator mode).
    case narration(URL)
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    @MainActor func apply() {
        switch self {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// A file or YouTube import in progress.
struct Activity: Equatable {
    var title: String
    /// 0...1, or nil while the duration is unknown.
    var progress: Double?
}

@MainActor
final class TranscriptionModel: ObservableObject {
    static let systemAudioSourceID = "system"

    // MARK: Transcript
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published private(set) var partialText = ""
    @Published private(set) var title = ""
    /// Set when the user named the transcript, so imports don't replace the name.
    private var titleChosen = false
    @Published private(set) var source: TranscriptSource = .live
    /// Where the transcript is saved; auto-save keeps writing to this file.
    @Published private(set) var savedURL: URL?
    @Published private(set) var hasUnsavedChanges = false
    private var startDate = Date()

    // MARK: Live transcription
    @Published private(set) var isRunning = false
    /// When the current live run started, for the elapsed-time display.
    @Published private(set) var runStartedAt: Date?
    @Published private(set) var level: Float = 0
    @Published private(set) var silentTooLong = false
    @Published private(set) var inputDevices: [AudioInputDevice] = []

    // MARK: Imports
    @Published private(set) var activity: Activity?
    @Published var showYouTubeImport = false
    private var importTask: Task<Void, Never>?

    @Published var errorMessage: String?

    @Published private(set) var locales: [Locale] = []
    @Published private(set) var installedLocaleIDs: Set<String> = []
    @AppStorage("localeIdentifier") var localeIdentifier = Locale.current.identifier
    /// Languages used to transcribe, most recent first.
    @Published private(set) var recentLocaleIDs: [String] {
        didSet { defaults.set(recentLocaleIDs, forKey: "recentLocales") }
    }

    // MARK: Speech recognition
    @Published var speechEngine: SpeechEngine {
        didSet {
            defaults.set(speechEngine.rawValue, forKey: "speechEngine")
            refreshWhisperModel()
        }
    }
    @Published var whisperModel: WhisperModel {
        didSet {
            defaults.set(whisperModel.rawValue, forKey: "whisperModel")
            refreshWhisperModel()
        }
    }
    /// A Hugging Face repository and model folder, used when `whisperModel` is `.custom`.
    @Published var whisperCustomRepo: String {
        didSet {
            defaults.set(whisperCustomRepo, forKey: "whisperCustomRepo")
            refreshWhisperModel()
        }
    }
    @Published var whisperCustomVariant: String {
        didSet {
            defaults.set(whisperCustomVariant, forKey: "whisperCustomVariant")
            refreshWhisperModel()
        }
    }
    /// Whether the selected Whisper model is on this Mac.
    @Published private(set) var isWhisperModelDownloaded = false
    /// Whether `whisperParameters` apply; otherwise the defaults do.
    @Published var expertOptions: Bool { didSet { defaults.set(expertOptions, forKey: "expertOptions") } }
    @Published var whisperParameters: WhisperParameters {
        didSet { defaults.set(try? JSONEncoder().encode(whisperParameters), forKey: "whisperParameters") }
    }
    /// What Whisper uses: the defaults, or the expert options when they're turned on.
    var effectiveWhisperParameters: WhisperParameters { expertOptions ? whisperParameters.clamped : .standard }

    // MARK: Transcript folder (sidebar)
    /// Whether the transcript folder is shown on the left of the window.
    @Published var showsSidebar: Bool { didSet { defaults.set(showsSidebar, forKey: "showsSidebar") } }
    /// Changes whenever the app changed the transcript folder, so the sidebar lists it again.
    @Published private(set) var folderVersion = 0
    /// Shows the Rename Transcript dialog.
    @Published var showRenameTranscript = false

    // MARK: Settings
    /// `systemAudioSourceID` or the UID of an input device.
    @Published var audioSourceID: String { didSet { defaults.set(audioSourceID, forKey: "audioSource") } }
    @Published var recordAudio: Bool { didSet { defaults.set(recordAudio, forKey: "recordAudio") } }
    @Published var autosaveEnabled: Bool {
        didSet {
            defaults.set(autosaveEnabled, forKey: "autosave")
            autosave()
        }
    }
    @Published var saveFolder: URL { didSet { defaults.set(saveFolder.path, forKey: "saveFolder") } }
    @Published var ytDLPPath: String {
        didSet {
            defaults.set(ytDLPPath, forKey: "ytDLPPath")
            refreshYTDLP(after: 0.6)
        }
    }
    /// When on, imported files become subtitles timed to each word instead of paragraphs.
    @Published var narratorMode: Bool { didSet { defaults.set(narratorMode, forKey: "narratorMode") } }
    @Published var subtitleStyle: SubtitleStyle {
        didSet {
            defaults.set(subtitleStyle.rawValue, forKey: "subtitleStyle")
            rebuildSubtitles()
        }
    }
    @Published var frameRate: VideoFrameRate { didSet { defaults.set(frameRate.rawValue, forKey: "frameRate") } }
    @Published var appearance: AppAppearance {
        didSet {
            defaults.set(appearance.rawValue, forKey: "appearance")
            appearance.apply()
        }
    }

    var usesWhisper: Bool { speechEngine == .whisper }
    /// Whether the selected language can be transcribed right now with the selected engine.
    var isSelectedLocaleInstalled: Bool {
        guard usesWhisper else { return installedLocaleIDs.contains(localeIdentifier) }
        return isWhisperModelDownloaded && WhisperEngine.languageCode(for: Locale(identifier: localeIdentifier)) != nil
    }
    var isIdle: Bool { !isRunning && activity == nil }
    var canStartNewTranscript: Bool { isIdle && !segments.isEmpty }
    var usesMicrophone: Bool { audioSourceID != Self.systemAudioSourceID }
    var selectedInputDevice: AudioInputDevice? { inputDevices.first { $0.uid == audioSourceID } }
    /// The yt-dlp imports use; nil if none was found (or while `isCheckingYTDLP` on first launch).
    @Published private(set) var ytDLP: YouTubeImporter.Tool?
    @Published private(set) var isCheckingYTDLP = false
    private var ytDLPCheck: Task<Void, Never>?

    private let defaults = UserDefaults.standard
    private var capture: AudioCapture?
    private var transcriber: SpeechTranscribing?
    private var recorder: AudioRecorder?
    private var lastSoundAt = Date()
    private var lastAutosaveError: String?
    /// Set once the user agreed to close, so the window and the app don't both ask.
    private var closeApproved = false

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    static var defaultSaveFolder: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Transcriber", isDirectory: true)
    }

    init() {
        audioSourceID = defaults.string(forKey: "audioSource") ?? Self.systemAudioSourceID
        recordAudio = defaults.bool(forKey: "recordAudio")
        autosaveEnabled = defaults.object(forKey: "autosave") as? Bool ?? true
        saveFolder = defaults.string(forKey: "saveFolder").map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultSaveFolder
        ytDLPPath = defaults.string(forKey: "ytDLPPath") ?? ""
        appearance = defaults.string(forKey: "appearance").flatMap(AppAppearance.init(rawValue:)) ?? .system
        narratorMode = defaults.bool(forKey: "narratorMode")
        subtitleStyle = defaults.string(forKey: "subtitleStyle").flatMap(SubtitleStyle.init(rawValue:)) ?? .standard
        frameRate = defaults.string(forKey: "frameRate").flatMap(VideoFrameRate.init(rawValue:)) ?? .fps30
        recentLocaleIDs = defaults.stringArray(forKey: "recentLocales") ?? []
        speechEngine = defaults.string(forKey: "speechEngine").flatMap(SpeechEngine.init(rawValue:)) ?? .apple
        whisperModel = defaults.string(forKey: "whisperModel").flatMap(WhisperModel.init(rawValue:)) ?? .turboCompressed
        whisperCustomRepo = defaults.string(forKey: "whisperCustomRepo") ?? WhisperModel.defaultRepo
        whisperCustomVariant = defaults.string(forKey: "whisperCustomVariant") ?? ""
        expertOptions = defaults.bool(forKey: "expertOptions")
        whisperParameters = defaults.data(forKey: "whisperParameters")
            .flatMap { try? JSONDecoder().decode(WhisperParameters.self, from: $0) } ?? .standard
        showsSidebar = defaults.bool(forKey: "showsSidebar")
        refreshWhisperModel()

        refreshLocales()
        if !locales.contains(where: { $0.identifier == localeIdentifier }) {
            localeIdentifier = Self.preferredLocale(in: locales.filter { installedLocaleIDs.contains($0.identifier) })?.identifier
                ?? locales.first?.identifier
                ?? localeIdentifier
        }
        refreshInputDevices()
        AudioInputDevice.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.refreshInputDevices() }
        }
        refreshYTDLP()
        // Pick up language models and yt-dlp updates installed while the app was in the background.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshLocales()
                self?.refreshYTDLP()
            }
        }
    }

    /// Looks for yt-dlp again (it takes a moment, since each copy is asked for its version).
    func refreshYTDLP(after delay: TimeInterval = 0) {
        ytDLPCheck?.cancel()
        ytDLPCheck = Task { [weak self, ytDLPPath] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled else { return }
            self?.isCheckingYTDLP = true
            let tool = await YouTubeImporter.findTool(customPath: ytDLPPath)
            guard !Task.isCancelled else { return }
            self?.ytDLP = tool
            self?.isCheckingYTDLP = false
        }
    }

    // MARK: - Languages

    func refreshLocales() {
        let available = LiveTranscriber.availableLocales()
        locales = available.all
        installedLocaleIDs = available.installed
    }

    /// Opens System Settings › Keyboard, where Dictation languages (and their on-device models) are added.
    func openDictationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func displayName(for locale: Locale) -> String {
        LiveTranscriber.displayName(for: locale)
    }

    var selectedLanguageName: String {
        LiveTranscriber.displayName(for: Locale(identifier: localeIdentifier))
    }

    /// Up to five recently used languages, newest first.
    var recentLocales: [Locale] {
        recentLocaleIDs.compactMap { id in locales.first { $0.identifier == id } }
    }

    /// Moves the selected language to the top of the recently used list.
    private func markSelectedLocaleUsed() {
        recentLocaleIDs = Array(([localeIdentifier] + recentLocaleIDs.filter { $0 != localeIdentifier }).prefix(5))
    }

    private static func preferredLocale(in candidates: [Locale]) -> Locale? {
        for preferred in Locale.preferredLanguages.map(Locale.init(identifier:)) {
            let matches = candidates.filter { $0.language.languageCode == preferred.language.languageCode }
            if let exact = matches.first(where: { $0.region == preferred.region }) ?? matches.first { return exact }
        }
        return candidates.first
    }

    // MARK: - Whisper

    /// Where the selected Whisper model comes from; nil if a custom model isn't filled in.
    var whisperModelSource: WhisperEngine.ModelSource? {
        guard whisperModel == .custom else {
            return WhisperEngine.ModelSource(repo: WhisperModel.defaultRepo, variant: whisperModel.rawValue)
        }
        let repo = whisperCustomRepo.trimmingCharacters(in: .whitespaces)
        let variant = whisperCustomVariant.trimmingCharacters(in: .whitespaces)
        guard !repo.isEmpty, !variant.isEmpty else { return nil }
        return WhisperEngine.ModelSource(repo: repo, variant: variant)
    }

    func refreshWhisperModel() {
        isWhisperModelDownloaded = whisperModelSource.map(WhisperEngine.isDownloaded) ?? false
        // Load the model in the background so Start doesn't have to wait for it.
        if usesWhisper, isWhisperModelDownloaded, let source = whisperModelSource {
            Task { try? await WhisperEngine.shared.prepare(source) }
        }
    }

    /// Downloads the selected Whisper model from Hugging Face. Transcription itself never leaves this Mac.
    func downloadWhisperModel() {
        guard isIdle else { return }
        runImport(Activity(title: "Downloading the Whisper model…", progress: 0)) { [self] in
            try await prepareWhisper()
        }
    }

    func revealWhisperModels() {
        let folder = WhisperEngine.modelsFolder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }

    /// Downloads and loads the Whisper model if needed, showing what happens in `activity`.
    private func prepareWhisper() async throws {
        guard let source = whisperModelSource else { throw WhisperEngine.EngineError.noModel }
        guard await !WhisperEngine.shared.isLoaded(source) else { return }
        let previous = activity
        defer {
            activity = previous
            refreshWhisperModel()
        }
        activity = WhisperEngine.isDownloaded(source)
            ? Activity(title: "Loading the Whisper model…")
            : Activity(title: "Downloading the Whisper model…", progress: 0)
        try await WhisperEngine.shared.prepare(source) { progress in
            Task { @MainActor [weak self] in
                guard let self, self.activity != nil else { return }
                if let progress {
                    if self.activity?.progress != nil { self.activity?.progress = progress }
                } else {
                    // Core ML specializes the model for this Mac the first time; later loads are quick.
                    self.activity = Activity(title: "Preparing the Whisper model for this Mac (the first time can take a few minutes)…")
                }
            }
        }
    }

    // MARK: - Audio sources

    func refreshInputDevices() {
        inputDevices = AudioInputDevice.all()
    }

    private func makeCapture() throws -> AudioCapture {
        guard usesMicrophone else { return SystemAudioCapture() }
        guard let device = selectedInputDevice else { throw MicrophoneCapture.CaptureError.disconnected }
        return MicrophoneCapture(device: device)
    }

    // MARK: - Live transcription

    func toggle() {
        if isRunning {
            stop()
        } else {
            Task { await start() }
        }
    }

    func start() async {
        guard isIdle else { return }
        errorMessage = nil
        if usesWhisper {
            do {
                try await prepareWhisper()
            } catch {
                errorMessage = error.localizedDescription
                return
            }
        } else {
            guard await LiveTranscriber.requestAuthorization() else {
                errorMessage = LiveTranscriber.TranscriberError.notAuthorized.errorDescription
                return
            }
        }
        if usesMicrophone, !(await MicrophoneCapture.requestAuthorization()) {
            errorMessage = MicrophoneCapture.CaptureError.notAuthorized.errorDescription
            return
        }
        // Continue a live transcript after Stop; anything else starts a new one.
        if source != .live || segments.isEmpty {
            guard beginTranscript(title: Self.liveTitle(), source: .live) else { return }
        }

        var transcriber: SpeechTranscribing?
        do {
            let locale = Locale(identifier: localeIdentifier)
            let live: SpeechTranscribing = usesWhisper
                ? WhisperLiveTranscriber(locale: locale, parameters: effectiveWhisperParameters)
                : try LiveTranscriber(locale: locale)
            transcriber = live
            live.onPartial = { [weak self] text in self?.partialText = text }
            live.onFinal = { [weak self] text in
                guard let self else { return }
                self.append([TranscriptSegment(offset: Date().timeIntervalSince(self.startDate), text: text)])
            }
            live.onLevel = { [weak self] level in
                DispatchQueue.main.async { self?.updateLevel(level) }
            }
            live.start()

            let recorder = recordAudio ? AudioRecorder(url: try uniqueURL(pathExtension: "m4a")) : nil
            recorder?.onError = { [weak self] error in
                self?.errorMessage = "Couldn't save the audio: \(error.localizedDescription)"
            }
            let capture = try makeCapture()
            try capture.start { [weak live] buffer in
                recorder?.append(buffer)
                live?.append(buffer)
            }

            self.transcriber = live
            self.capture = capture
            self.recorder = recorder
            lastSoundAt = Date()
            silentTooLong = false
            isRunning = true
            markSelectedLocaleUsed()
            runStartedAt = Date()
        } catch {
            transcriber?.stop(completion: nil)
            errorMessage = error.localizedDescription
        }
    }

    /// `completion` runs once the last segment has been added (and auto-saved).
    func stop(completion: (() -> Void)? = nil) {
        capture?.stop()
        capture = nil
        recorder?.finish()
        recorder = nil
        let finishing = transcriber
        transcriber = nil
        isRunning = false
        runStartedAt = nil
        level = 0
        silentTooLong = false
        if let finishing {
            finishing.stop(completion: { completion?() })
        } else {
            completion?()
        }
    }

    private func updateLevel(_ newLevel: Float) {
        guard isRunning else { return }
        level = newLevel
        let now = Date()
        if newLevel > 0.0005 { lastSoundAt = now }
        // A denied audio permission delivers pure silence instead of an error.
        silentTooLong = now.timeIntervalSince(lastSoundAt) > 10
    }

    private static func liveTitle() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return "Transcript \(formatter.string(from: Date()))"
    }

    // MARK: - Transcript

    /// Clears the transcript (asking first if it isn't saved). The saved file is kept.
    @discardableResult
    func newTranscript() -> Bool {
        guard isIdle, confirmUnsavedChanges() else { return false }
        segments = []
        narrationWords = []
        subtitleCues = []
        partialText = ""
        title = ""
        titleChosen = false
        source = .live
        savedURL = nil
        hasUnsavedChanges = false
        lastAutosaveError = nil
        startDate = Date()
        return true
    }

    private func beginTranscript(title: String, source: TranscriptSource) -> Bool {
        // A name given before anything was transcribed is for this transcript.
        let chosen = segments.isEmpty && titleChosen ? self.title : nil
        guard newTranscript() else { return false }
        self.title = chosen ?? title
        titleChosen = chosen != nil
        self.source = source
        return true
    }

    /// Uses a title an import found (such as the video's), unless the user named the transcript.
    private func adoptTitle(_ title: String) {
        if !titleChosen { self.title = title }
    }

    /// Names the transcript, renaming its saved file along with the subtitles and audio next to it.
    func renameTranscript(_ newTitle: String) {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, title != self.title else { return }
        self.title = title
        titleChosen = true
        guard let savedURL else { return }
        do {
            self.savedURL = try TranscriptFolder.renameTranscript(savedURL, to: Self.fileName(from: title))
            folderVersion += 1
        } catch {
            errorMessage = "Couldn't rename the saved transcript: \(error.localizedDescription)"
        }
    }

    private func append(_ newSegments: [TranscriptSegment]) {
        guard !newSegments.isEmpty else { return }
        segments += newSegments
        hasUnsavedChanges = true
        autosave()
    }

    func timestamp(for segment: TranscriptSegment) -> String {
        guard source != .live else { return Self.timeFormatter.string(from: startDate.addingTimeInterval(segment.offset)) }
        let seconds = Int(segment.offset)
        let (hours, minutes) = (seconds / 3600, seconds / 60 % 60)
        if case .narration = source {
            // Subtitles need finer timing: show tenths of a second.
            let tenths = Int(segment.offset * 10) % 10
            return hours > 0
                ? String(format: "%d:%02d:%02d.%d", hours, minutes, seconds % 60, tenths)
                : String(format: "%02d:%02d.%d", minutes, seconds % 60, tenths)
        }
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds % 60)
            : String(format: "%02d:%02d", minutes, seconds % 60)
    }

    func transcriptText(includingPartial: Bool = true) -> String {
        var lines: [String] = []
        switch source {
        case .live: break
        case let .file(url), let .narration(url): lines += [title, "Source: \(url.lastPathComponent)", ""]
        case let .youtube(url): lines += [title, "Source: \(url.absoluteString)", ""]
        }
        lines += segments.map { "[\(timestamp(for: $0))] \($0.text)" }
        if includingPartial, !partialText.isEmpty { lines.append(partialText) }
        return lines.joined(separator: "\n")
    }

    // MARK: - Saving

    private func autosave() {
        guard autosaveEnabled, !segments.isEmpty else { return }
        do {
            let url = try savedURL ?? uniqueURL(pathExtension: "txt")
            try transcriptText(includingPartial: false).write(to: url, atomically: true, encoding: .utf8)
            if !subtitleCues.isEmpty {
                // Narrator mode: keep subtitles ready next to the transcript.
                try SubtitleWriter.srt(subtitleCues)
                    .write(to: url.deletingPathExtension().appendingPathExtension("srt"), atomically: true, encoding: .utf8)
            }
            if savedURL == nil { folderVersion += 1 }
            savedURL = url
            hasUnsavedChanges = false
            lastAutosaveError = nil
        } catch {
            // Report each distinct problem once instead of after every segment.
            let message = "Couldn't save the transcript automatically: \(error.localizedDescription)"
            if message != lastAutosaveError {
                lastAutosaveError = message
                errorMessage = message
            }
        }
    }

    /// A file in the save folder named after the transcript that doesn't exist yet.
    private func uniqueURL(pathExtension: String) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: saveFolder, withIntermediateDirectories: true)
        let base = Self.fileName(from: title)
        var url = saveFolder.appendingPathComponent(base).appendingPathExtension(pathExtension)
        var number = 2
        while fileManager.fileExists(atPath: url.path) {
            url = saveFolder.appendingPathComponent("\(base) \(number)").appendingPathExtension(pathExtension)
            number += 1
        }
        return url
    }

    private static func fileName(from title: String) -> String {
        let cleaned = title
            .components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.newlines))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? "Transcript" : String(cleaned.prefix(120))
    }

    func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptText(), forType: .string)
    }

    /// Asks where to save. Auto-save keeps writing to the chosen file afterwards.
    @discardableResult
    func save() -> Bool {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = (savedURL?.deletingPathExtension().lastPathComponent ?? Self.fileName(from: title)) + ".txt"
        panel.directoryURL = savedURL?.deletingLastPathComponent() ?? saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return false }
        do {
            try transcriptText(includingPartial: false).write(to: url, atomically: true, encoding: .utf8)
            savedURL = url
            hasUnsavedChanges = false
            return true
        } catch {
            errorMessage = "Could not save transcript: \(error.localizedDescription)"
            return false
        }
    }

    func revealInFinder() {
        if let savedURL {
            NSWorkspace.shared.activateFileViewerSelecting([savedURL])
        } else {
            try? FileManager.default.createDirectory(at: saveFolder, withIntermediateDirectories: true)
            NSWorkspace.shared.open(saveFolder)
        }
    }

    func chooseSaveFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = saveFolder
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        saveFolder = url
    }

    // MARK: - Transcript folder (sidebar)

    /// Creates "New Folder" in `parent`; returns it, or nil if that failed.
    @discardableResult
    func createFolder(in parent: URL) -> URL? {
        changeFolder(from: nil) { try TranscriptFolder.createFolder(in: parent) }
    }

    /// Returns the new location, or nil if renaming failed.
    @discardableResult
    func renameItem(_ url: URL, to name: String) -> URL? {
        changeFolder(from: url) { try TranscriptFolder.rename(url, to: name) }
    }

    /// Moves into `folder`; returns the new location, or nil if moving failed.
    @discardableResult
    func moveItem(_ url: URL, into folder: URL) -> URL? {
        changeFolder(from: url) { try TranscriptFolder.move(url, into: folder) }
    }

    /// If the open transcript (or the folder it's in) was moved or renamed, auto-save follows it; renaming the
    /// transcript's own file renames the transcript too.
    private func changeFolder(from source: URL?, _ change: () throws -> URL) -> URL? {
        defer { folderVersion += 1 }
        do {
            let destination = try change()
            if let source, let saved = savedURL {
                let renamedOwnFile = TranscriptFolder.samePath(saved, source)
                    && TranscriptFolder.samePath(source.deletingLastPathComponent(), destination.deletingLastPathComponent())
                savedURL = TranscriptFolder.relocated(saved, from: source, to: destination)
                if renamedOwnFile {
                    title = destination.deletingPathExtension().lastPathComponent
                    titleChosen = true
                }
            }
            return destination
        } catch {
            errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Asks, then moves a file or folder to the Trash. Returns whether it did.
    @discardableResult
    func deleteItem(_ url: URL) -> Bool {
        let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        let containsTranscript = savedURL.map { TranscriptFolder.samePath($0, url) || TranscriptFolder.isInside($0, url) } ?? false
        let alert = NSAlert()
        alert.messageText = "Move “\(url.lastPathComponent)” to the Trash?"
        alert.informativeText = containsTranscript
            ? "This includes the open transcript. If you keep transcribing, it's saved again as a new file."
            : isFolder ? "The folder and everything in it can be restored from the Trash."
            : "You can restore it from the Trash."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defer { folderVersion += 1 }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            if containsTranscript {
                savedURL = nil
                hasUnsavedChanges = !segments.isEmpty
            }
            return true
        } catch {
            errorMessage = "“\(url.lastPathComponent)” couldn't be moved to the Trash: \(error.localizedDescription)"
            return false
        }
    }

    // MARK: - Imports

    func chooseAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.message = narratorMode ? "Choose a voiceover to turn into subtitles."
                                     : "Choose a recording to transcribe, such as a voice memo."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        transcribeFile(url)
    }

    /// Transcribes a file, or in narrator mode turns it into subtitles.
    func transcribeFile(_ url: URL) {
        if narratorMode {
            transcribeVoiceover(url)
            return
        }
        guard isIdle, beginTranscript(title: url.deletingPathExtension().lastPathComponent, source: .file(url)) else { return }
        markSelectedLocaleUsed()
        runImport(Activity(title: "Transcribing “\(url.lastPathComponent)”…", progress: 0)) { [self] in
            try await recognize(url)
        }
    }

    func importYouTube(_ video: URL, useCaptions: Bool) {
        guard isIdle else { return }
        guard let tool = ytDLP else {
            errorMessage = YouTubeImporter.ImportError.notInstalled.errorDescription
            return
        }
        guard beginTranscript(title: "YouTube video", source: .youtube(video)) else { return }
        markSelectedLocaleUsed()
        let languageCode = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "en"

        runImport(Activity(title: useCaptions ? "Getting captions from YouTube…" : "Getting the video from YouTube…")) { [self] in
            let importer = YouTubeImporter(tool: tool)
            let workFolder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: workFolder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: workFolder) }

            var captionsFailed = false
            if useCaptions {
                do {
                    if let captions = try await importer.captions(for: video, languageCode: languageCode, in: workFolder) {
                        adoptTitle(captions.title)
                        append(captions.segments.map { TranscriptSegment(offset: $0.offset, text: $0.text) })
                        guard recordAudio else { return }
                        do {
                            let audio = try await downloadAudio(with: importer, from: video, into: workFolder, title: "Downloading the audio…")
                            try keepAudio(audio.file)
                        } catch let error as CancellationError {
                            throw error
                        } catch {
                            errorMessage = "The transcript is saved, but the audio couldn't be saved: \(error.localizedDescription)"
                        }
                        return
                    }
                } catch let error as CancellationError {
                    throw error
                } catch {
                    // Rate limits and the like often only affect captions; the audio may still work.
                    captionsFailed = true
                }
            }

            let status = !useCaptions ? "Downloading the audio…"
                : captionsFailed ? "Couldn't get captions. Downloading the audio…"
                : "No captions in this language. Downloading the audio…"
            let audio = try await downloadAudio(with: importer, from: video, into: workFolder, title: status)
            adoptTitle(audio.title)
            activity = Activity(title: "Transcribing “\(audio.title)”…", progress: 0)
            try await recognize(audio.file)
            if recordAudio { try keepAudio(audio.file) }
        }
    }

    private func downloadAudio(with importer: YouTubeImporter, from video: URL, into folder: URL,
                               title status: String) async throws -> (title: String, file: URL) {
        activity = Activity(title: status, progress: 0)
        return try await importer.downloadAudio(from: video, into: folder) { progress in
            Task { @MainActor [weak self] in
                if self?.activity?.progress != nil { self?.activity?.progress = progress }
            }
        }
    }

    /// Moves a downloaded audio file into the save folder, next to the transcript.
    private func keepAudio(_ file: URL) throws {
        do {
            try FileManager.default.moveItem(at: file, to: uniqueURL(pathExtension: file.pathExtension))
        } catch {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't save the audio: \(error.localizedDescription)"])
        }
    }

    func cancelImport() {
        importTask?.cancel()
    }

    private func recognize(_ url: URL) async throws {
        try await recognize(url) { [weak self] passage in
            self?.append([TranscriptSegment(offset: passage.start, text: passage.text)])
        }
    }

    private func recognize(_ url: URL, onPassage: @escaping @MainActor (FileTranscriber.Passage) -> Void) async throws {
        let locale = Locale(identifier: localeIdentifier)
        let transcriber: FileTranscriber
        if usesWhisper {
            try await prepareWhisper()
            transcriber = FileTranscriber(whisper: .shared, locale: locale, parameters: effectiveWhisperParameters)
        } else {
            guard await LiveTranscriber.requestAuthorization() else { throw LiveTranscriber.TranscriberError.notAuthorized }
            transcriber = try FileTranscriber(locale: locale)
        }
        try await transcriber.transcribe(url, onProgress: { [weak self] progress in
            self?.activity?.progress = progress
        }, onPassage: onPassage)
    }

    // MARK: - Narrator mode (subtitles)

    /// Words of the current voiceover, kept so subtitles can be re-flowed when the style changes.
    private var narrationWords: [TimedWord] = []
    @Published private(set) var subtitleCues: [SubtitleCue] = []

    var canExportSubtitles: Bool { !subtitleCues.isEmpty }

    var finalCutProURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.FinalCut") }

    private func transcribeVoiceover(_ url: URL) {
        guard isIdle, beginTranscript(title: url.deletingPathExtension().lastPathComponent, source: .narration(url)) else { return }
        markSelectedLocaleUsed()
        runImport(Activity(title: "Creating subtitles for “\(url.lastPathComponent)”…", progress: 0)) { [self] in
            try await recognize(url) { [weak self] passage in
                guard let self else { return }
                narrationWords += passage.words
                rebuildSubtitles()
            }
        }
    }

    /// Recomputes the subtitles from the voiceover's words and shows them as the transcript.
    private func rebuildSubtitles() {
        guard case .narration = source, !narrationWords.isEmpty else { return }
        subtitleCues = SubtitleBuilder.cues(from: narrationWords, style: subtitleStyle)
        segments = subtitleCues.map { TranscriptSegment(offset: $0.start, text: $0.text, end: $0.end) }
        hasUnsavedChanges = true
        autosave()
    }

    func exportSubtitles(_ format: SubtitleFormat) {
        guard canExportSubtitles, let contents = subtitleFile(format) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.fileName(from: title) + "." + format.fileExtension
        panel.directoryURL = savedURL?.deletingLastPathComponent() ?? saveFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try contents.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Couldn't export the subtitles: \(error.localizedDescription)"
        }
    }

    /// Writes a Final Cut Pro project next to the transcript and opens it, which imports it into Final Cut Pro.
    func openInFinalCutPro() {
        guard let finalCutPro = finalCutProURL, let contents = subtitleFile(.finalCutPro) else { return }
        do {
            let url = try savedURL.map { $0.deletingPathExtension().appendingPathExtension("fcpxml") }
                ?? uniqueURL(pathExtension: "fcpxml")
            try contents.write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open([url], withApplicationAt: finalCutPro, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            errorMessage = "Couldn't create the Final Cut Pro project: \(error.localizedDescription)"
        }
    }

    private func subtitleFile(_ format: SubtitleFormat) -> String? {
        switch format {
        case .srt:
            return SubtitleWriter.srt(subtitleCues)
        case .webVTT:
            return SubtitleWriter.webVTT(subtitleCues)
        case .finalCutPro:
            guard case let .narration(audioURL) = source else { return nil }
            let file = try? AVAudioFile(forReading: audioURL)
            let audio = SubtitleWriter.AudioInfo(
                url: audioURL,
                duration: file.map { Double($0.length) / $0.fileFormat.sampleRate } ?? (subtitleCues.last?.end ?? 0),
                channels: Int(file?.fileFormat.channelCount ?? 2),
                sampleRate: Int(file?.fileFormat.sampleRate ?? 48_000))
            let language = Locale(identifier: localeIdentifier).language.languageCode?.identifier ?? "en"
            return SubtitleWriter.finalCutPro(subtitleCues, audio: audio, title: "\(title) – Subtitles",
                                              languageCode: language, frameRate: frameRate)
        }
    }

    private func runImport(_ activity: Activity, _ work: @escaping () async throws -> Void) {
        errorMessage = nil
        self.activity = activity
        importTask = Task { [weak self] in
            do {
                try await work()
            } catch {
                if !(error is CancellationError), !Task.isCancelled { self?.errorMessage = error.localizedDescription }
            }
            self?.activity = nil
            self?.importTask = nil
        }
    }

    // MARK: - Closing

    var needsConfirmationBeforeClosing: Bool { !closeApproved && (!isIdle || hasUnsavedChanges) }

    /// Called by the window before it closes. Asks first if needed, then closes it itself.
    func windowShouldClose(_ window: NSWindow) -> Bool {
        guard needsConfirmationBeforeClosing else { return true }
        DispatchQueue.main.async { [weak self, weak window] in
            self?.requestClose { approved in
                guard approved else { return }
                self?.closeApproved = true
                window?.close()
            }
        }
        return false
    }

    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        guard needsConfirmationBeforeClosing else { return .terminateNow }
        DispatchQueue.main.async { [self] in
            requestClose { approved in
                if approved { self.closeApproved = true }
                NSApp.reply(toApplicationShouldTerminate: approved)
            }
        }
        return .terminateLater
    }

    /// Stops running work and offers to save, asking at each step. `completion` gets whether to go ahead.
    private func requestClose(_ completion: @escaping (Bool) -> Void) {
        if activity != nil {
            guard confirm("An import is still in progress.",
                          "Quitting cancels it. The text transcribed so far is kept.",
                          proceed: "Cancel Import and Quit") else { return completion(false) }
            cancelImport()
        }
        if isRunning {
            guard confirm("Transcription is still running.",
                          autosaveEnabled ? "Transcriber stops listening and saves the transcript before quitting."
                                          : "Transcriber stops listening before quitting.",
                          proceed: "Stop and Quit") else { return completion(false) }
            stop { [self] in completion(confirmUnsavedChanges()) }
            return
        }
        completion(confirmUnsavedChanges())
    }

    /// Returns false if the user wants to keep the current transcript.
    private func confirmUnsavedChanges() -> Bool {
        guard hasUnsavedChanges, !segments.isEmpty else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save the transcript?"
        alert.informativeText = autosaveEnabled
            ? "It couldn't be saved automatically. If you don't save it, it will be lost."
            : "Auto-save is off. If you don't save the transcript, it will be lost."
        alert.addButton(withTitle: "Save…")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don't Save")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return save()
        case .alertThirdButtonReturn:
            hasUnsavedChanges = false
            return true
        default:
            return false
        }
    }

    private func confirm(_ message: String, _ information: String, proceed: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = information
        alert.addButton(withTitle: proceed)
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}
