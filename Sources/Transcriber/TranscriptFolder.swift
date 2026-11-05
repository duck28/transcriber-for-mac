import Foundation

/// The transcript folder, as the sidebar shows and changes it: listing, new folders, renaming and moving.
/// (Moving to the Trash asks first, so it lives in `TranscriptionModel.deleteItem`.)
enum TranscriptFolder {
    /// A file or folder in the transcript folder.
    struct Item: Identifiable, Hashable {
        let url: URL
        let isFolder: Bool
        /// What's in a folder; nil for files.
        var children: [Item]?

        var id: URL { url }
        var name: String { url.lastPathComponent }
    }

    enum FolderError: LocalizedError {
        case invalidName
        case exists(String)
        case intoItself

        var errorDescription: String? {
            switch self {
            case .invalidName: return "Enter a name that doesn't start with a period and doesn't contain “/” or “:”."
            case let .exists(name): return "There's already an item named “(name)” there."
            case .intoItself: return "A folder can't be moved into itself."
            }
        }
    }

    /// Everything in `folder` at any depth, folders first, each sorted by name like Finder. Creates the folder.
    static func items(in folder: URL) throws -> [Item] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let urls = try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                                                       options: [.skipsHiddenFiles])
        return urls.map { url -> Item in
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            let isFolder = values?.isDirectory == true && values?.isPackage != true
            return Item(url: url, isFolder: isFolder, children: isFolder ? ((try? items(in: url)) ?? []) : nil)
        }
        .sorted { a, b in
            a.isFolder != b.isFolder ? a.isFolder : a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// Creates a folder named `name` (or "name 2" and so on) in `parent` and returns it.
    static func createFolder(in parent: URL, named name: String = "New Folder") throws -> URL {
        var url = parent.appendingPathComponent(name, isDirectory: true)
        var number = 2
        while exists(url) {
            url = parent.appendingPathComponent("\(name) \(number)", isDirectory: true)
            number += 1
        }
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Renames a file or folder in place and returns its new location.
    static func rename(_ url: URL, to newName: String) throws -> URL {
        let name = try validName(newName)
        let target = url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: url.hasDirectoryPath)
        // Changing only the capitalization renames the same item.
        if exists(target), !samePath(target, url) { throw FolderError.exists(name) }
        try move(url, to: target)
        return target
    }

    /// Moves a file or folder into `folder` and returns its new location.
    static func move(_ url: URL, into folder: URL) throws -> URL {
        let target = folder.appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath)
        if samePath(target, url) { return url }
        if samePath(folder, url) || isInside(folder, url) { throw FolderError.intoItself }
        if exists(target) { throw FolderError.exists(url.lastPathComponent) }
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    /// Renames a saved transcript to `base` plus its extension, along with the files next to it that share its
    /// name (subtitles, audio). Picks "base 2" and so on if any of the new names is taken. Returns the new location.
    static func renameTranscript(_ url: URL, to base: String) throws -> URL {
        let base = try validName(base)
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent.lowercased()
        let siblings = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { !$0.hasDirectoryPath && !samePath($0, url) && $0.deletingPathExtension().lastPathComponent.lowercased() == stem }

        func renamed(_ file: URL, to newBase: String) -> URL {
            let named = folder.appendingPathComponent(newBase)
            return file.pathExtension.isEmpty ? named : named.appendingPathExtension(file.pathExtension)
        }
        func isTaken(_ newBase: String) -> Bool {
            ([url] + siblings).contains { file in
                let target = renamed(file, to: newBase)
                return exists(target) && !samePath(target, file)
            }
        }
        var newBase = base
        var number = 2
        while isTaken(newBase) {
            newBase = "\(base) \(number)"
            number += 1
        }

        let target = renamed(url, to: newBase)
        try move(url, to: target)
        for sibling in siblings {
            try? move(sibling, to: renamed(sibling, to: newBase))
        }
        return target
    }

    /// Where `url` ends up after `source` was moved or renamed to `destination` (unchanged if it isn't `source`
    /// or inside it).
    static func relocated(_ url: URL, from source: URL, to destination: URL) -> URL {
        if samePath(url, source) { return destination }
        guard isInside(url, source) else { return url }
        let rest = String(url.standardizedFileURL.path.dropFirst(source.standardizedFileURL.path.count + 1))
        return destination.appendingPathComponent(rest)
    }

    /// Paths on the Mac's usual file system don't care about capitalization.
    static func samePath(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.path.lowercased() == b.standardizedFileURL.path.lowercased()
    }

    /// Whether `url` is somewhere inside `folder`.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        url.standardizedFileURL.path.lowercased().hasPrefix(folder.standardizedFileURL.path.lowercased() + "/")
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    /// The name, trimmed, if it can name a file or folder (and wouldn't hide it).
    private static func validName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains(":") else {
            throw FolderError.invalidName
        }
        return name
    }

    /// Moves `url` to `target`, also when only the capitalization changes (which a plain move refuses).
    private static func move(_ url: URL, to target: URL) throws {
        guard url.lastPathComponent != target.lastPathComponent || !samePath(url, target) else { return }
        let fileManager = FileManager.default
        if samePath(url, target) {
            let temporary = url.deletingLastPathComponent().appendingPathComponent(".rename-\(UUID().uuidString)")
            try fileManager.moveItem(at: url, to: temporary)
            try fileManager.moveItem(at: temporary, to: target)
        } else {
            try fileManager.moveItem(at: url, to: target)
        }
    }
}
