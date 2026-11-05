import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: TranscriptionModel
    @State private var isDropTargeted = false
    @State private var renameText = ""

    /// Whether new text scrolls into view: only while the transcript is scrolled to the end.
    @State private var followsNewText = true
    @State private var lastContentTop: CGFloat = 0
    @State private var viewportHeight: CGFloat = 0

    // The transcript folder pane
    @State private var window: NSWindow?
    @State private var showsPane = false
    /// While the window grows or shrinks for the pane, the transcript keeps this width and the pane takes the rest.
    @State private var pinnedContentWidth: CGFloat?
    /// The pane's width where the window can't change size, so the pane grows into the window instead.
    @State private var paneWidth = BookWindow.paneWidth
    @State private var contentWidth: CGFloat = 0
    /// Whether opening the pane widened the window, so closing it gives the room back.
    @State private var grewWindow = false

    var body: some View {
        HStack(spacing: 0) {
            if showsPane {
                // The page stays against the spine (the transcript), so it's revealed rather than squeezed.
                TranscriptSidebar()
                    .frame(width: BookWindow.paneWidth)
                    .frame(width: pinnedContentWidth == nil ? paneWidth : nil, alignment: .trailing)
                    // While the window moves, the pane takes whatever the pinned transcript leaves (from nothing).
                    .frame(minWidth: pinnedContentWidth == nil ? nil : 0,
                           maxWidth: pinnedContentWidth == nil ? nil : .infinity, alignment: .trailing)
                    .clipped()
                    .overlay(alignment: .trailing) { Divider() }
            }
            main
                .frame(width: pinnedContentWidth)
        }
        .navigationTitle(titleBinding)
        .navigationSubtitle(statusText)
        .toolbar { toolbar }
        .sheet(isPresented: $model.showYouTubeImport) {
            YouTubeImportSheet().environmentObject(model)
        }
        .alert("Rename Transcript", isPresented: $model.showRenameTranscript) {
            TextField("Name", text: $renameText)
            Button("Rename") { model.renameTranscript(renameText) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(model.segments.isEmpty ? "The next transcript gets this name." : "Its saved file is renamed too.")
        }
        .onChange(of: model.showRenameTranscript) { _, isShown in
            if isShown { renameText = model.title }
        }
        .background(WindowCloseGuard(shouldClose: model.windowShouldClose))
        .background(WindowReader { window = $0 })
        .onAppear {
            // A window reopened with the pane already has room for it.
            showsPane = model.showsSidebar
            grewWindow = model.showsSidebar
        }
        .onChange(of: model.showsSidebar) { _, isOpen in setPane(isOpen) }
    }

    /// Clicking the window title renames the transcript (File › Rename Transcript… does too).
    private var titleBinding: Binding<String> {
        Binding(get: { model.title.isEmpty ? "Transcriber" : model.title },
                set: { model.renameTranscript($0) })
    }

    private var main: some View {
        ScrollViewReader { proxy in
            transcript
                .safeAreaInset(edge: .top, spacing: 0) { notices }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        if !followsNewText && (model.isRunning || model.activity != nil) {
                            latestButton(proxy)
                        }
                        controlBar
                    }
                }
                .onChange(of: model.segments.count) {
                    if model.segments.isEmpty { followsNewText = true }
                    if followsNewText { withAnimation { proxy.scrollTo("bottom") } }
                }
                .onChange(of: model.partialText) {
                    if followsNewText { proxy.scrollTo("bottom") }
                }
        }
        .overlay { if isDropTargeted { dropHighlight } }
        .frame(minWidth: BookWindow.minContentWidth, minHeight: 420)
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { contentWidth = geometry.size.width }
                    .onChange(of: geometry.size.width) { _, width in contentWidth = width }
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, model.isIdle else { return false }
            model.transcribeFile(url)
            return true
        } isTargeted: { isDropTargeted = $0 && model.isIdle }
    }

    private var statusText: String {
        let count = model.segments.count == 1 ? "1 segment" : "\(model.segments.count) segments"
        if model.segments.isEmpty { return "Transcribed on this Mac" }
        if model.hasUnsavedChanges { return "\(count) · Not saved" }
        if let url = model.savedURL { return "\(count) · Saved to \(url.lastPathComponent)" }
        return count
    }

    // MARK: - Transcript folder pane

    /// Opens or closes the transcript folder like a book: the window grows on the right by the pane's width while
    /// the pane unfolds on the left, so the transcript keeps its size. A window that can't change size (zoomed or
    /// in full screen) keeps it, and the pane takes its room from the transcript.
    private func setPane(_ isOpen: Bool) {
        if let window, isOpen || grewWindow, BookWindow.canResize(window) {
            pinnedContentWidth = contentWidth
            if isOpen { showsPane = true }
            grewWindow = isOpen
            // Let the pinned layout land before the window starts to move.
            DispatchQueue.main.async {
                BookWindow.resize(window, opening: isOpen) {
                    pinnedContentWidth = nil
                    if !isOpen { showsPane = false }
                }
            }
        } else if isOpen {
            grewWindow = false
            paneWidth = 0
            showsPane = true
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: BookWindow.duration)) { paneWidth = BookWindow.paneWidth }
            }
        } else {
            withAnimation(.easeOut(duration: BookWindow.duration)) {
                paneWidth = 0
            } completion: {
                showsPane = false
                paneWidth = BookWindow.paneWidth
            }
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.showsSidebar.toggle()
            } label: {
                Label("Transcripts", systemImage: "sidebar.left")
            }
            .help(model.showsSidebar ? "Hide the transcript folder (⌃⌘S)" : "Show the transcript folder (⌃⌘S)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Toggle(isOn: $model.narratorMode) {
                Label("Narrator Mode", systemImage: "captions.bubble")
            }
            .disabled(!model.isIdle)
            .help(model.narratorMode ? "Narrator mode is on: imported voiceovers become timed subtitles"
                                     : "Turn on narrator mode to turn voiceovers into timed subtitles")

            if model.canExportSubtitles {
                Menu {
                    ForEach(SubtitleFormat.allCases) { format in
                        Button(format.menuTitle) { model.exportSubtitles(format) }
                    }
                    if model.finalCutProURL != nil {
                        Divider()
                        Button("Open in Final Cut Pro", systemImage: "film", action: model.openInFinalCutPro)
                    }
                } label: {
                    Label("Export Subtitles", systemImage: "square.and.arrow.up")
                }
                .help("Export the subtitles for DaVinci Resolve, Premiere Pro or Final Cut Pro")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Button(model.narratorMode ? "Voiceover…" : "Audio File…", systemImage: "waveform", action: model.chooseAudioFile)
                Button("YouTube Video…", systemImage: "play.rectangle") { model.showYouTubeImport = true }
            } label: {
                Label("Import", systemImage: "plus")
            }
            .disabled(!model.isIdle || !model.isSelectedLocaleInstalled)
            .help("Transcribe a recording, such as a voice memo, or a YouTube video")

            Button("New Transcript", systemImage: "square.and.pencil") { model.newTranscript() }
                .disabled(!model.canStartNewTranscript)
                .help("Start a new transcript (⌘N)")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button("Copy", systemImage: "doc.on.doc", action: model.copyToClipboard)
                .disabled(model.segments.isEmpty)
                .help("Copy the transcript")
            Button("Save As…", systemImage: "square.and.arrow.down") { model.save() }
                .disabled(model.segments.isEmpty)
                .help("Save the transcript to a file of your choice (⇧⌘S)")
            Button("Show in Finder", systemImage: "folder", action: model.revealInFinder)
                .help("Show the saved transcript in Finder")
        }
    }

    // MARK: - Transcript

    private var transcript: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(model.segments) { segment in
                    SegmentRow(timestamp: model.timestamp(for: segment), text: segment.text)
                }
                if !model.partialText.isEmpty {
                    SegmentRow(timestamp: nil, text: model.partialText)
                }
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(maxWidth: 780)
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: ContentFrameKey.self, value: geometry.frame(in: .named("transcript")))
                }
            }
        }
        .coordinateSpace(.named("transcript"))
        .background {
            GeometryReader { geometry in
                Color.clear
                    .onAppear { viewportHeight = geometry.size.height }
                    .onChange(of: geometry.size.height) { _, height in viewportHeight = height }
            }
        }
        .onPreferenceChange(ContentFrameKey.self) { frame in contentMoved(frame) }
        .overlay {
            if model.segments.isEmpty && model.partialText.isEmpty { emptyState }
        }
    }

    /// Follows new text while the transcript is scrolled to the end, and stops once the user scrolls back to read.
    private func contentMoved(_ frame: CGRect) {
        // Within the control bar's height of the end counts as the end.
        let isAtEnd = frame.maxY - viewportHeight < 120
        // Scrolling new text into view only ever moves the content up, so content moving down is the user
        // scrolling back. (Removing the preview line can move it down too, but then the view is still at the end.)
        if isAtEnd {
            followsNewText = true
        } else if frame.minY > lastContentTop + 1 {
            followsNewText = false
        }
        lastContentTop = frame.minY
    }

    /// Shown while new text arrives but the user has scrolled back to read.
    private func latestButton(_ proxy: ScrollViewProxy) -> some View {
        Button {
            followsNewText = true
            withAnimation { proxy.scrollTo("bottom") }
        } label: {
            Label("Latest", systemImage: "arrow.down")
        }
        .glassButtonStyle()
        .controlSize(.small)
        .help("Jump to the newest text")
        .padding(.top, 8)
        .transition(.opacity)
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.isRunning {
            ContentUnavailableView {
                Label("Listening…", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative, isActive: true)
            } description: {
                Text(model.usesMicrophone ? "Start speaking. Text appears after each pause."
                                          : "Play something on your Mac. Text appears after each pause.")
            }
        } else if let activity = model.activity {
            ContentUnavailableView {
                Label("Working on It", systemImage: "text.badge.checkmark")
            } description: {
                Text(activity.title)
            }
        } else if model.narratorMode {
            ContentUnavailableView {
                Label("Narrator Mode", systemImage: "captions.bubble")
            } description: {
                Text("Drop a voiceover here to turn it into subtitles timed to every word. Export them as SRT for DaVinci Resolve and Premiere Pro, or as a Final Cut Pro project with the voiceover and captions already in sync.")
            } actions: {
                Button("Choose Voiceover…", systemImage: "waveform", action: model.chooseAudioFile)
                    .glassButtonStyle(prominent: true)
                    .disabled(!model.isSelectedLocaleInstalled)
            }
        } else {
            ContentUnavailableView {
                Label("Ready to Transcribe", systemImage: "waveform.and.mic")
            } description: {
                Text(model.usesMicrophone ? "Press the record button to transcribe what your microphone hears, or transcribe a recording or a YouTube video. You can also drop an audio file here."
                                          : "Press the record button to transcribe whatever your Mac is playing, or transcribe a recording or a YouTube video. You can also drop an audio file here.")
            } actions: {
                Button("Transcribe a File…", systemImage: "waveform", action: model.chooseAudioFile)
                    .glassButtonStyle()
                    .disabled(!model.isSelectedLocaleInstalled)
                Button("YouTube Video…", systemImage: "play.rectangle") { model.showYouTubeImport = true }
                    .glassButtonStyle()
                    .disabled(!model.isSelectedLocaleInstalled)
            }
        }
    }

    private var dropHighlight: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                Label("Drop to Transcribe", systemImage: "arrow.down.doc")
                    .font(.title3.weight(.medium))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .glassSurface()
            }
            .padding(12)
            .allowsHitTesting(false)
    }

    // MARK: - Notices

    @ViewBuilder
    private var notices: some View {
        VStack(spacing: 8) {
            if let activity = model.activity {
                ActivityCard(activity: activity, onCancel: model.cancelImport)
            }
            if let error = model.errorMessage {
                NoticeCard(text: error, systemImage: "exclamationmark.triangle.fill", tint: .red) {
                    model.errorMessage = nil
                }
            } else if model.usesWhisper && !model.isSelectedLocaleInstalled {
                whisperNotice
            } else if !model.isSelectedLocaleInstalled && !model.locales.isEmpty {
                NoticeCard(text: "The offline speech model for this language isn't on your Mac yet. In System Settings › Keyboard › Dictation, turn Dictation on, then add this language under Languages › Edit…. Transcriber picks it up once the download finishes.",
                           systemImage: "arrow.down.circle.fill", tint: .blue, onClose: nil,
                           action: ("Open Keyboard Settings", model.openDictationSettings))
            } else if model.silentTooLong {
                NoticeCard(text: silenceHint, systemImage: "speaker.slash.fill", tint: .orange, onClose: nil)
            }
        }
        .frame(maxWidth: 720)
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .animation(.spring(duration: 0.35), value: model.activity)
        .animation(.spring(duration: 0.35), value: model.errorMessage)
    }

    @ViewBuilder
    private var whisperNotice: some View {
        if model.whisperModelSource == nil {
            NoticeCard(text: "Enter the custom Whisper model in Settings › Speech Recognition.",
                       systemImage: "gearshape.fill", tint: .blue, onClose: nil)
        } else if !model.isWhisperModelDownloaded {
            NoticeCard(text: "Whisper needs its speech model on your Mac: \(model.whisperModel.title). It's downloaded once from Hugging Face; after that, transcription runs entirely on this Mac, even offline.",
                       systemImage: "arrow.down.circle.fill", tint: .blue, onClose: nil,
                       action: whisperDownloadAction)
        } else {
            NoticeCard(text: "Whisper doesn't support this language. Choose another one, or switch to Apple Speech in Settings.",
                       systemImage: "globe", tint: .orange, onClose: nil)
        }
    }

    private var whisperDownloadAction: (title: String, perform: () -> Void)? {
        guard model.activity == nil else { return nil }
        return ("Download Model", { model.downloadWhisperModel() })
    }

    private var silenceHint: String {
        if let device = model.selectedInputDevice {
            return "No sound from “\(device.name)”. Check that it's the right microphone, or allow Transcriber under System Settings › Privacy & Security › Microphone."
        }
        return "No audio received. Play something, or allow Transcriber under System Settings › Privacy & Security › Screen & System Audio Recording (System Audio Recording Only), then restart it."
    }

    // MARK: - Control bar

    private var controlBar: some View {
        GlassGroup(spacing: 16) {
            HStack(spacing: 16) {
                inputControls
                    .frame(maxWidth: .infinity, alignment: .trailing)
                RecordButton(isRunning: model.isRunning, action: model.toggle)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(!model.isRunning && (!model.isIdle || !model.isSelectedLocaleInstalled))
                    .help(model.isRunning ? "Stop transcribing (⌘R)" : "Start transcribing (⌘R)")
                meterControls
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 18)
    }

    private var inputControls: some View {
        HStack(spacing: 2) {
            Menu {
                Picker("Source", selection: $model.audioSourceID) {
                    Label("System Audio", systemImage: "speaker.wave.2").tag(TranscriptionModel.systemAudioSourceID)
                    if !model.inputDevices.isEmpty { Divider() }
                    ForEach(model.inputDevices) { device in
                        Label(device.name, systemImage: "mic").tag(device.uid)
                    }
                    if model.usesMicrophone && model.selectedInputDevice == nil {
                        Label("Disconnected Microphone", systemImage: "mic.slash").tag(model.audioSourceID)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(sourceName, systemImage: model.usesMicrophone ? "mic.fill" : "speaker.wave.2.fill")
            }
            .disabled(model.isRunning)
            .help("What to transcribe: everything your Mac plays, or a microphone")

            Divider().frame(height: 18).padding(.horizontal, 6)

            Menu {
                languageMenuItems
            } label: {
                Label(model.selectedLanguageName, systemImage: "globe")
            }
            .disabled(!model.isIdle || model.locales.isEmpty)
            .help("Language to transcribe. Languages under Needs Download work once their Dictation model is installed.")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 14)
        .frame(height: 40)
        .glassSurface()
    }

    private var meterControls: some View {
        HStack(spacing: 12) {
            Waveform(level: model.level, isActive: model.isRunning)
            Group {
                if let start = model.runStartedAt {
                    Text(start, style: .timer)
                } else {
                    Text("0:00").foregroundStyle(.secondary)
                }
            }
            .font(.callout.monospacedDigit())
            .frame(minWidth: 40, alignment: .leading)

            Button {
                model.recordAudio.toggle()
            } label: {
                Image(systemName: model.recordAudio ? "waveform.circle.fill" : "waveform.circle")
                    .font(.title3)
                    .foregroundStyle(model.recordAudio ? Color.red : Color.secondary)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .disabled(model.isRunning)
            .help(model.recordAudio ? "Saving audio next to the transcript. Click to turn off."
                                    : "Also save the audio next to the transcript")
        }
        .padding(.horizontal, 14)
        .frame(height: 40)
        .glassSurface()
    }

    private var sourceName: String {
        guard model.usesMicrophone else { return "System Audio" }
        return model.selectedInputDevice?.name ?? "Disconnected Microphone"
    }

    /// Recently used languages first, then the ones ready on this Mac, then the ones that need a download.
    @ViewBuilder
    private var languageMenuItems: some View {
        if !model.recentLocales.isEmpty {
            Section("Recently Used") {
                ForEach(model.recentLocales, id: \.identifier, content: languageItem)
            }
        }
        if model.usesWhisper {
            // Whisper handles every language it knows with one model, so there's nothing to install per language.
            Section("Whisper") {
                ForEach(model.locales.filter { WhisperEngine.languageCode(for: $0) != nil },
                        id: \.identifier, content: languageItem)
            }
        } else {
            appleLanguageSections
        }
    }

    @ViewBuilder
    private var appleLanguageSections: some View {
        let installed = model.locales.filter { model.installedLocaleIDs.contains($0.identifier) }
        let downloadable = model.locales.filter { !model.installedLocaleIDs.contains($0.identifier) }
        if !installed.isEmpty {
            Section("On This Mac") {
                ForEach(installed, id: \.identifier, content: languageItem)
            }
        }
        if !downloadable.isEmpty {
            Section("Needs Download") {
                ForEach(downloadable, id: \.identifier, content: languageItem)
            }
        }
    }

    /// A menu item with a checkmark for the selected language.
    private func languageItem(_ locale: Locale) -> some View {
        Toggle(model.displayName(for: locale), isOn: Binding(
            get: { model.localeIdentifier == locale.identifier },
            set: { if $0 { model.localeIdentifier = locale.identifier } }))
    }
}

// MARK: - Pieces

/// Where the transcript's content is in its scroll view.
private struct ContentFrameKey: PreferenceKey {
    static let defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct SegmentRow: View {
    /// nil for the text that is still being recognized.
    let timestamp: String?
    let text: String
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(timestamp ?? "")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
            Text(text)
                .font(.body)
                .lineSpacing(3)
                .foregroundStyle(timestamp == nil ? .secondary : .primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 12)
        .background(isHovered ? Color.primary.opacity(0.05) : .clear,
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Copy Paragraph", systemImage: "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        }
    }
}

private struct RecordButton: View {
    let isRunning: Bool
    let action: () -> Void
    @State private var pulse = false

    var body: some View {
        Button(action: action) {
            RoundedRectangle(cornerRadius: isRunning ? 6 : 16, style: .continuous)
                .fill(Color.red.gradient)
                .frame(width: isRunning ? 22 : 32, height: isRunning ? 22 : 32)
                .frame(width: 58, height: 58)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassSurface(in: Circle(), interactive: true)
        .background {
            if isRunning {
                Circle()
                    .stroke(Color.red.opacity(0.6), lineWidth: 2)
                    .scaleEffect(pulse ? 1.45 : 1)
                    .opacity(pulse ? 0 : 1)
                    .onAppear {
                        pulse = false
                        withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
                    }
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: isRunning)
        .accessibilityLabel(isRunning ? "Stop" : "Start")
    }
}

/// A scrolling bar graph of the recent audio level.
private struct Waveform: View {
    let level: Float
    let isActive: Bool
    @State private var history = Array(repeating: CGFloat(0), count: 24)
    @State private var peak: CGFloat = 0
    @State private var lastPush = Date.distantPast

    var body: some View {
        HStack(spacing: 2) {
            ForEach(history.indices, id: \.self) { index in
                Capsule()
                    .fill(isActive ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.secondary.opacity(0.35)))
                    .frame(width: 3, height: max(3, history[index] * 22))
            }
        }
        .frame(height: 24)
        .animation(.linear(duration: 0.08), value: history)
        .onChange(of: level) { _, newLevel in
            // Levels arrive per audio buffer; keep the loudest and add one bar every ~70 ms.
            peak = max(peak, Self.normalized(newLevel))
            let now = Date()
            guard now.timeIntervalSince(lastPush) > 0.07 else { return }
            history.removeFirst()
            history.append(peak)
            peak = 0
            lastPush = now
        }
        .onChange(of: isActive) { _, active in
            if !active { history = Array(repeating: 0, count: history.count) }
        }
        .help("Audio level")
        .accessibilityHidden(true)
    }

    /// Maps RMS to a perceptual 0...1 range (-60 dB ... 0 dB).
    private static func normalized(_ level: Float) -> CGFloat {
        let db = 20 * log10(max(level, 0.000_001))
        return CGFloat(min(max((db + 60) / 60, 0), 1))
    }
}

private struct ActivityCard: View {
    let activity: Activity
    let onCancel: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            if let progress = activity.progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(activity.title)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let progress = activity.progress {
                Text(progress, format: .percent.precision(.fractionLength(0)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button("Cancel", action: onCancel)
                .glassButtonStyle()
                .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private struct NoticeCard: View {
    let text: String
    let systemImage: String
    let tint: Color
    let onClose: (() -> Void)?
    var action: (title: String, perform: () -> Void)? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
            VStack(alignment: .leading, spacing: 8) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action.title, action: action.perform)
                        .glassButtonStyle()
                        .controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            if let onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
            }
        }
        .padding(14)
        .glassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - YouTube

private struct YouTubeImportSheet: View {
    @EnvironmentObject private var model: TranscriptionModel
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var useCaptions = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "play.rectangle.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(.red)
                    .symbolRenderingMode(.hierarchical)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Import from YouTube").font(.title3.weight(.semibold))
                    Text("Language: \(languageName)").font(.callout).foregroundStyle(.secondary)
                }
            }

            TextField("Video link", text: $link, prompt: Text("https://www.youtube.com/watch?v=…"))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .glassSurface(in: RoundedRectangle(cornerRadius: 12, style: .continuous))

            Picker("Method", selection: $useCaptions) {
                Text("Use YouTube's captions if there are any (fast)").tag(true)
                Text("Download the audio and transcribe it on this Mac").tag(false)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()

            Text("If the video has no captions in this language, the audio is transcribed instead.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            YTDLPStatus()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .glassButtonStyle()
                Button("Import") {
                    guard let video else { return }
                    dismiss()
                    model.importYouTube(video, useCaptions: useCaptions)
                }
                .keyboardShortcut(.defaultAction)
                .glassButtonStyle(prominent: true)
                .disabled(video == nil || model.ytDLP == nil)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 480)
        .onAppear {
            // Offer a YouTube link that's already on the clipboard.
            if let copied = NSPasteboard.general.string(forType: .string), Self.youTubeURL(from: copied) != nil {
                link = copied.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    private var video: URL? { Self.youTubeURL(from: link) }

    private var languageName: String { model.selectedLanguageName }

    private static func youTubeURL(from text: String) -> URL? {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased(),
              host == "youtu.be" || host == "youtube.com" || host.hasSuffix(".youtube.com") else { return nil }
        return url
    }
}

/// Which yt-dlp is used, and how to install or update it.
struct YTDLPStatus: View {
    @EnvironmentObject private var model: TranscriptionModel

    var body: some View {
        Group {
            if let tool = model.ytDLP {
                if tool.isOutdated {
                    warning("yt-dlp \(tool.version) is out of date, and YouTube regularly breaks older versions. Update it in Terminal:",
                            command: tool.updateCommand)
                } else {
                    Text("Using yt-dlp \(tool.version) (\(tool.url.path))")
                        .foregroundStyle(.secondary)
                }
            } else if model.isCheckingYTDLP {
                Text("Looking for yt-dlp…").foregroundStyle(.secondary)
            } else {
                warning("Importing from YouTube needs yt-dlp. Install it in Terminal, then come back to Transcriber:",
                        command: "pip3 install -U \"yt-dlp[default]\"")
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func warning(_ text: String, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            HStack {
                Text(command)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                }
                .controlSize(.small)
            }
        }
    }
}
