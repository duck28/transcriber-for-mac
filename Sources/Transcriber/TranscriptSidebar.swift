import AppKit
import SwiftUI

/// The transcript folder on the left of the window, like the left page of an open book: make folders, rename
/// (Return), move by dragging onto a folder or with Move To, and move to the Trash (⌘⌫). Double-click opens a file.
struct TranscriptSidebar: View {
    @EnvironmentObject private var model: TranscriptionModel
    @State private var items: [TranscriptFolder.Item] = []
    @State private var loadError: String?
    @State private var expanded: Set<URL> = []
    @State private var selection: URL?
    @State private var renaming: URL?
    @State private var dropTarget: URL?

    var body: some View {
        VStack(spacing: 0) {
            header
            List(selection: $selection) {
                ForEach(items) { item in node(item) }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: URL.self) { urls in
                menu(for: urls.first)
            } primaryAction: { urls in
                if let url = urls.first { open(url) }
            }
            .onDeleteCommand {
                if let selection { delete(selection) }
            }
            .onKeyPress(.return) {
                guard renaming == nil, let selection else { return .ignored }
                renaming = selection
                return .handled
            }
            // Dropping on the empty space below the items moves into the transcript folder itself.
            .dropDestination(for: URL.self) { urls, _ in
                move(urls, into: model.saveFolder)
            }
            .overlay {
                if let emptyMessage {
                    Text(emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(20)
                }
            }
            Text("Drag files onto a folder to move them.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
        }
        .background(.background.secondary)
        .onAppear(perform: reload)
        .onChange(of: model.folderVersion) { reload() }
        .onChange(of: model.saveFolder) { reload() }
        // Pick up changes made in Finder.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
    }

    private var header: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 1) {
                Text("Transcripts").font(.headline)
                Text(model.saveFolder.lastPathComponent)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button { newFolder(in: newFolderParent) } label: {
                Image(systemName: "folder.badge.plus")
            }
            .help("New folder")
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .help("Refresh")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var emptyMessage: String? {
        if let loadError { return "Couldn't open the transcript folder: \(loadError)" }
        return items.isEmpty ? "No transcripts yet. They're saved here automatically." : nil
    }

    // MARK: - Rows

    /// A row, with its contents below it if it's a folder. (Type-erased, because it's recursive.)
    private func node(_ item: TranscriptFolder.Item) -> AnyView {
        guard let children = item.children else { return AnyView(row(item)) }
        return AnyView(DisclosureGroup(isExpanded: expansion(of: item.url)) {
            ForEach(children) { child in node(child) }
        } label: {
            row(item)
        })
    }

    private func row(_ item: TranscriptFolder.Item) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon(for: item))
                .foregroundStyle(item.isFolder ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 16)
            if let renaming, TranscriptFolder.samePath(renaming, item.url) {
                RenameField(name: item.name) { finishRename(item, newName: $0) }
            } else {
                Text(item.name)
                    .fontWeight(isCurrent(item) ? .semibold : .regular)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 1)
        .background(isDropTarget(item) ? Color.accentColor.opacity(0.25) : .clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous))
        .tag(item.url)
        .help(isCurrent(item) ? "\(item.name) (the open transcript)" : item.name)
        .draggable(item.url)
        // Dropping on a file moves into the folder it's in.
        .dropDestination(for: URL.self) { urls, _ in
            move(urls, into: item.isFolder ? item.url : item.url.deletingLastPathComponent())
        } isTargeted: { targeted in
            if targeted {
                dropTarget = item.isFolder ? item.url : nil
            } else if dropTarget == item.url {
                dropTarget = nil
            }
        }
    }

    private func icon(for item: TranscriptFolder.Item) -> String {
        if item.isFolder { return expanded.contains(item.url) ? "folder.fill" : "folder" }
        switch item.url.pathExtension.lowercased() {
        case "txt": return "doc.text"
        case "srt", "vtt", "fcpxml": return "captions.bubble"
        case "m4a", "mp3", "wav", "aac", "flac", "aif", "aiff", "caf", "mp4", "mov", "m4v": return "waveform"
        default: return "doc"
        }
    }

    private func isCurrent(_ item: TranscriptFolder.Item) -> Bool {
        model.savedURL.map { TranscriptFolder.samePath($0, item.url) } ?? false
    }

    private func isDropTarget(_ item: TranscriptFolder.Item) -> Bool {
        item.isFolder && dropTarget == item.url
    }

    private func expansion(of url: URL) -> Binding<Bool> {
        Binding(get: { expanded.contains(url) },
                set: { isExpanded in
                    if isExpanded { expanded.insert(url) } else { expanded.remove(url) }
                })
    }

    // MARK: - Menu

    @ViewBuilder
    private func menu(for url: URL?) -> some View {
        if let url, let item = findItem(at: url) {
            if item.isFolder {
                Button("New Folder Inside", systemImage: "folder.badge.plus") { newFolder(in: item.url) }
            } else {
                Button("Open", systemImage: "arrow.up.forward.app") { NSWorkspace.shared.open(item.url) }
            }
            Button("Rename", systemImage: "pencil") { renaming = item.url }
            Button("Show in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            }
            let targets = moveTargets(for: item)
            if !targets.isEmpty {
                Menu("Move To") {
                    ForEach(targets, id: \.self) { folder in
                        Button(relativeName(of: folder)) { _ = move([item.url], into: folder) }
                    }
                }
            }
            Divider()
            Button("Move to Trash", systemImage: "trash") { delete(item.url) }
        } else {
            Button("New Folder", systemImage: "folder.badge.plus") { newFolder(in: model.saveFolder) }
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.open(model.saveFolder) }
            Button("Refresh", systemImage: "arrow.clockwise", action: reload)
            Divider()
            Button("Choose Another Folder…", action: model.chooseSaveFolder)
        }
    }

    /// Where an item can be moved: the transcript folder and every folder in it, except where it already is and
    /// (for a folder) itself and what's inside it.
    private func moveTargets(for item: TranscriptFolder.Item) -> [URL] {
        let parent = item.url.deletingLastPathComponent()
        return ([model.saveFolder] + allFolders(in: items)).filter { folder in
            !TranscriptFolder.samePath(folder, parent) && !TranscriptFolder.samePath(folder, item.url)
                && !TranscriptFolder.isInside(folder, item.url)
        }
    }

    private func allFolders(in items: [TranscriptFolder.Item]) -> [URL] {
        items.flatMap { item in item.children.map { [item.url] + allFolders(in: $0) } ?? [] }
    }

    /// "Council › 2026" for a folder inside the transcript folder.
    private func relativeName(of folder: URL) -> String {
        guard TranscriptFolder.isInside(folder, model.saveFolder) else { return model.saveFolder.lastPathComponent }
        let root = model.saveFolder.standardizedFileURL.pathComponents.count
        return folder.standardizedFileURL.pathComponents.dropFirst(root).joined(separator: " › ")
    }

    private func findItem(at url: URL, in items: [TranscriptFolder.Item]? = nil) -> TranscriptFolder.Item? {
        for item in items ?? self.items {
            if TranscriptFolder.samePath(item.url, url) { return item }
            if let children = item.children, let found = findItem(at: url, in: children) { return found }
        }
        return nil
    }

    // MARK: - Changes

    private func reload() {
        do {
            items = try TranscriptFolder.items(in: model.saveFolder)
            loadError = nil
        } catch {
            items = []
            loadError = error.localizedDescription
        }
    }

    /// Where New Folder goes: into the selected folder, otherwise next to the selected file.
    private var newFolderParent: URL {
        guard let selection, let item = findItem(at: selection) else { return model.saveFolder }
        return item.isFolder ? item.url : item.url.deletingLastPathComponent()
    }

    private func newFolder(in parent: URL) {
        guard let folder = model.createFolder(in: parent) else { return }
        if !TranscriptFolder.samePath(parent, model.saveFolder) { expanded.insert(parent) }
        reload()
        let url = findItem(at: folder)?.url ?? folder
        selection = url
        renaming = url
    }

    private func finishRename(_ item: TranscriptFolder.Item, newName: String?) {
        renaming = nil
        guard let newName, !newName.trimmingCharacters(in: .whitespaces).isEmpty, newName != item.name else { return }
        if let renamed = model.renameItem(item.url, to: newName) { follow(item.url, to: renamed) }
    }

    /// Moves items from the transcript folder into `folder`. Files dragged in from elsewhere are left alone.
    @discardableResult
    private func move(_ urls: [URL], into folder: URL) -> Bool {
        let movable = urls.filter { TranscriptFolder.isInside($0, model.saveFolder) }
        guard !movable.isEmpty else { return false }
        for url in movable {
            if let moved = model.moveItem(url, into: folder) { follow(url, to: moved) }
        }
        if !TranscriptFolder.samePath(folder, model.saveFolder) { expanded.insert(folder) }
        return true
    }

    private func delete(_ url: URL) {
        guard model.deleteItem(url) else { return }
        selection = nil
        expanded = expanded.filter { !TranscriptFolder.samePath($0, url) && !TranscriptFolder.isInside($0, url) }
    }

    /// Double-click: opens a file, or opens and closes a folder.
    private func open(_ url: URL) {
        guard let item = findItem(at: url) else { return }
        if item.isFolder {
            if expanded.contains(item.url) { expanded.remove(item.url) } else { expanded.insert(item.url) }
        } else {
            NSWorkspace.shared.open(item.url)
        }
    }

    /// Keeps expanded folders and the selection on an item that moved.
    private func follow(_ source: URL, to destination: URL) {
        expanded = Set(expanded.map { TranscriptFolder.relocated($0, from: source, to: destination) })
        selection = selection.map { TranscriptFolder.relocated($0, from: source, to: destination) }
    }
}

/// A field for renaming in place: Return or clicking elsewhere renames, Escape cancels.
private struct RenameField: View {
    let name: String
    let onDone: (String?) -> Void
    @State private var text = ""
    @State private var isFinished = false
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Name", text: $text)
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear {
                text = name
                DispatchQueue.main.async { isFocused = true }
            }
            .onSubmit { finish(text) }
            .onExitCommand { finish(nil) }
            .onChange(of: isFocused) { _, focused in
                if !focused { finish(text) }
            }
    }

    private func finish(_ value: String?) {
        guard !isFinished else { return }
        isFinished = true
        onDone(value)
    }
}

// MARK: - Opening like a book

/// Grows and shrinks the window for the transcript folder, like opening and closing a book: the window gets wider
/// on the right by the pane's width while the pane unfolds on the left, so the transcript keeps its size.
enum BookWindow {
    static let paneWidth: CGFloat = 280
    /// The transcript's smallest width (ContentView).
    static let minContentWidth: CGFloat = 660
    static let duration: TimeInterval = 0.24

    /// A window zoomed to fill the screen, or in full screen, keeps its size; the pane takes room from the transcript.
    @MainActor
    static func canResize(_ window: NSWindow) -> Bool {
        !window.styleMask.contains(.fullScreen) && !window.isZoomed
    }

    /// Animates the window to its new width, staying on the screen. AppKit lays the window out on every frame of
    /// the animation, so a pane that takes whatever the transcript leaves follows the window edge exactly.
    @MainActor
    static func resize(_ window: NSWindow, opening: Bool, completion: @escaping () -> Void) {
        var frame = window.frame
        if opening {
            frame.size.width += paneWidth
            if let screen = window.screen?.visibleFrame {
                frame.size.width = min(frame.width, screen.width)
                frame.origin.x = max(screen.minX, min(frame.minX, screen.maxX - frame.width))
            }
        } else {
            frame.size.width = max(frame.width - paneWidth, minContentWidth)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().setFrame(frame, display: true)
        } completionHandler: {
            completion()
        }
    }
}

/// Hands over the window this view is in.
struct WindowReader: NSViewRepresentable {
    let onWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> ReaderView {
        ReaderView(onWindow: onWindow)
    }

    func updateNSView(_ view: ReaderView, context: Context) {}

    final class ReaderView: NSView {
        let onWindow: (NSWindow) -> Void

        init(onWindow: @escaping (NSWindow) -> Void) {
            self.onWindow = onWindow
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            // Not during SwiftUI's view update.
            DispatchQueue.main.async { [onWindow] in onWindow(window) }
        }
    }
}
