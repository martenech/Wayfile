import AppKit
import Foundation
import UniformTypeIdentifiers

/// Ways to copy a path to the clipboard.
enum PathFormat: String, CaseIterable, Identifiable {
    case path, relative, shell, fileURL, name

    var id: String { rawValue }

    var title: String {
        switch self {
        case .path: return String(localized: "Path")
        case .relative: return String(localized: "Relative Path")
        case .shell: return String(localized: "Shell-Escaped Path")
        case .fileURL: return String(localized: "File URL")
        case .name: return String(localized: "Name")
        }
    }

    /// One line per item. Relative paths are relative to `base` (the git root or current folder).
    func string(for urls: [URL], relativeTo base: URL?) -> String {
        urls.map { url in
            switch self {
            case .path: return url.path
            case .relative:
                guard let base else { return url.path }
                let root = base.standardizedFileURL.path
                let path = url.standardizedFileURL.path
                return path.hasPrefix(root + "/") ? String(path.dropFirst(root.count + 1)) : path
            case .shell: return PathFormat.shellQuote(url.path)
            case .fileURL: return url.absoluteString
            case .name: return url.lastPathComponent
            }
        }
        .joined(separator: self == .shell ? " " : "\n")
    }

    /// POSIX single-quoting: safe for any character, including spaces, $, quotes and newlines.
    static func shellQuote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Extra commands that only make sense for some file types.
enum TypeActions {
    enum ImageFormat: String, CaseIterable, Identifiable {
        case jpeg, png, heic, tiff
        var id: String { rawValue }
        var title: String { rawValue.uppercased() }
        var fileExtension: String { self == .jpeg ? "jpg" : rawValue }
    }

    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .svg)
    }

    static func isEditableText(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .text) || type.conforms(to: .sourceCode)
    }

    /// Rotates by replacing the original (moved to the Trash, so Undo brings it back).
    static func rotate(_ urls: [URL], degrees: Int, progress: OperationProgress) async throws -> [URL] {
        progress.setTotals(bytes: 0, items: urls.count)
        var results: [URL] = []
        for url in urls {
            try progress.checkCancelled()
            progress.begin(url.lastPathComponent)
            let temp = url.deletingLastPathComponent().appendingPathComponent(".wayfile-rotate-\(UUID().uuidString).\(url.pathExtension)")
            try await Shell.check("/usr/bin/sips", ["-r", String(degrees), url.path, "--out", temp.path])
            var trashed: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
            if let trashed { progress.record(.trashed([TrashedItem(original: url, trashed: trashed as URL)])) }
            try FileManager.default.moveItem(at: temp, to: url)
            progress.record(.created([url]))
            results.append(url)
            progress.finishItem(baseline: 0, size: 0)
        }
        return results
    }

    /// Writes converted copies next to the originals ("photo.heic" → "photo.jpg").
    static func convert(_ urls: [URL], to format: ImageFormat, progress: OperationProgress) async throws -> [URL] {
        progress.setTotals(bytes: 0, items: urls.count)
        var results: [URL] = []
        for url in urls {
            try progress.checkCancelled()
            progress.begin(url.lastPathComponent)
            let target = FileOps.uniqueURL(url.deletingPathExtension().appendingPathExtension(format.fileExtension))
            try await Shell.check("/usr/bin/sips", ["-s", "format", format.rawValue, url.path, "--out", target.path])
            progress.record(.created([target]))
            results.append(target)
            progress.finishItem(baseline: 0, size: 0)
        }
        return results
    }

    static func setDesktopPicture(_ url: URL) throws {
        for screen in NSScreen.screens {
            try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: [:])
        }
    }
}
