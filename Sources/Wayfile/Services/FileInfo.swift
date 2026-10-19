import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

// MARK: - Hashes

struct FileHashes: Equatable {
    let md5: String
    let sha1: String
    let sha256: String
    let sha512: String

    var all: [(name: String, value: String)] {
        [("MD5", md5), ("SHA-1", sha1), ("SHA-256", sha256), ("SHA-512", sha512)]
    }

    /// Name of the algorithm whose digest equals `candidate` (case/whitespace-insensitive).
    func match(_ candidate: String) -> String? {
        let normalized = candidate.lowercased().filter { !$0.isWhitespace }
        guard !normalized.isEmpty else { return nil }
        return all.first { $0.value == normalized }?.name
    }
}

enum Hashing {
    /// Reads the file once and feeds all four hashers. Cancellable; reports progress 0…1.
    static func hashes(of url: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> FileHashes {
        let task = Task.detached(priority: .userInitiated) { () throws -> FileHashes in
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let total = Double((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            var md5 = Insecure.MD5()
            var sha1 = Insecure.SHA1()
            var sha256 = SHA256()
            var sha512 = SHA512()
            var read = 0.0
            var reported = 0.0
            while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
                try Task.checkCancellation()
                md5.update(data: chunk)
                sha1.update(data: chunk)
                sha256.update(data: chunk)
                sha512.update(data: chunk)
                read += Double(chunk.count)
                if total > 0, read / total - reported >= 0.01 {
                    reported = read / total
                    progress(reported)
                }
            }
            return FileHashes(md5: md5.finalize().hex, sha1: sha1.finalize().hex,
                              sha256: sha256.finalize().hex, sha512: sha512.finalize().hex)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }
}

extension Hashing {
    /// Streaming SHA-256 on the calling thread (for verification inside background operations).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().hex
    }

    /// Confirms `copy` has the same files with the same contents as `original` (file or folder tree).
    /// Returns the relative paths that differ or are missing.
    static func differences(between original: URL, and copy: URL, progress: OperationProgress? = nil) throws -> [String] {
        func files(in root: URL) -> [String: URL] {
            guard FileSystem.isDirectory(root) else { return ["": root] }
            var result: [String: URL] = [:]
            // Path-based enumeration yields relative paths directly (no /var vs /private/var prefix games).
            let enumerator = FileManager.default.enumerator(atPath: root.path)
            while let relative = enumerator?.nextObject() as? String {
                guard enumerator?.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                result["/" + relative] = root.appendingPathComponent(relative)
            }
            return result
        }
        let left = files(in: original), right = files(in: copy)
        var different = Set(left.keys).symmetricDifference(right.keys)
        for (path, url) in left {
            try progress?.checkCancelled()
            guard let other = right[path] else { continue }
            if try sha256(of: url) != sha256(of: other) { different.insert(path) }
        }
        return different.sorted().map { $0.isEmpty ? original.lastPathComponent : original.lastPathComponent + $0 }
    }
}

private extension Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}

// MARK: - Sizes

struct SizeSummary: Equatable {
    var bytes: Int64 = 0
    var allocated: Int64 = 0
    var files = 0
    var folders = 0
    var isComplete = false
}

enum SizeCalculator {
    /// Recursively totals `urls`, yielding running totals so large folders fill in progressively.
    static func summarize(_ urls: [URL]) -> AsyncStream<SizeSummary> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .totalFileAllocatedSizeKey]
                var summary = SizeSummary()
                var sinceYield = 0

                func add(_ url: URL) {
                    guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return }
                    if v.isDirectory == true && v.isSymbolicLink != true {
                        summary.folders += 1
                    } else {
                        summary.files += 1
                        summary.bytes += Int64(v.fileSize ?? 0)
                        summary.allocated += Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
                    }
                }

                for url in urls {
                    add(url)
                    guard FileSystem.isDirectory(url) else { continue }
                    let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true })
                    while let child = enumerator?.nextObject() as? URL {
                        if Task.isCancelled { continuation.finish(); return }
                        add(child)
                        sinceYield += 1
                        if sinceYield >= 2000 {
                            sinceYield = 0
                            continuation.yield(summary)
                        }
                    }
                }
                summary.isComplete = true
                continuation.yield(summary)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Permissions

struct Permissions: Equatable {
    var mode: Int
    let owner: String
    let group: String
    var isLocked: Bool

    static let classes = ["Owner", "Group", "Everyone"]
    static let bits = ["Read", "Write", "Execute"]

    /// Bit for class index (0 owner, 1 group, 2 others) and permission index (0 r, 1 w, 2 x).
    static func bit(_ cls: Int, _ perm: Int) -> Int { 1 << ((2 - cls) * 3 + (2 - perm)) }

    var octal: String { String(mode & 0o777, radix: 8) }

    /// "rwxr-xr-x" for raw mode bits.
    static func symbolic(_ mode: UInt16) -> String {
        Permissions(mode: Int(mode), owner: "", group: "", isLocked: false).symbolic
    }

    var symbolic: String {
        (0..<3).map { cls in
            ["r", "w", "x"].enumerated().map { perm, ch in mode & Self.bit(cls, perm) != 0 ? ch : "-" }.joined()
        }.joined()
    }

    static func read(_ url: URL) -> Permissions? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return Permissions(
            mode: (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0,
            owner: attrs[.ownerAccountName] as? String ?? "—",
            group: attrs[.groupOwnerAccountName] as? String ?? "—",
            isLocked: (attrs[.immutable] as? NSNumber)?.boolValue ?? false
        )
    }

    func apply(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: mode & 0o7777), .immutable: NSNumber(value: isLocked)],
            ofItemAtPath: url.path
        )
    }
}

// MARK: - Metadata

struct MetadataRow: Identifiable {
    let label: String
    let value: String
    var id: String { label }
}

struct MetadataSection: Identifiable {
    let title: String
    let rows: [MetadataRow]
    var id: String { title }
}

enum Metadata {
    static func sections(for url: URL) async -> [MetadataSection] {
        let type = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType) ?? .data
        var sections: [MetadataSection] = []
        if type.conforms(to: .image) { sections += image(url) }
        if type.conforms(to: .audiovisualContent) { sections += await media(url) }
        if type.conforms(to: .pdf), let pdf = pdf(url) { sections.append(pdf) }
        if let origin = origin(url) { sections.append(origin) }
        return sections
    }

    private static func image(_ url: URL) -> [MetadataSection] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [] }
        var image: [MetadataRow] = []
        if let w = props[kCGImagePropertyPixelWidth], let h = props[kCGImagePropertyPixelHeight] {
            image.append(MetadataRow(label: "Dimensions", value: "\(w) × \(h)"))
        }
        if let dpi = props[kCGImagePropertyDPIWidth] as? Double { image.append(MetadataRow(label: "Resolution", value: "\(Int(dpi)) dpi")) }
        if let model = props[kCGImagePropertyColorModel] as? String { image.append(MetadataRow(label: "Color model", value: model)) }
        if let profile = props[kCGImagePropertyProfileName] as? String { image.append(MetadataRow(label: "Color profile", value: profile)) }
        if let depth = props[kCGImagePropertyDepth] { image.append(MetadataRow(label: "Bit depth", value: "\(depth)")) }

        var camera: [MetadataRow] = []
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let make = tiff[kCGImagePropertyTIFFMake] as? String
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        if make != nil || model != nil {
            camera.append(MetadataRow(label: "Camera", value: [make, model].compactMap { $0 }.joined(separator: " ")))
        }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { camera.append(MetadataRow(label: "Lens", value: lens)) }
        if let taken = exif[kCGImagePropertyExifDateTimeOriginal] as? String { camera.append(MetadataRow(label: "Taken", value: taken)) }
        if let focal = exif[kCGImagePropertyExifFocalLength] as? Double { camera.append(MetadataRow(label: "Focal length", value: "\(focal.formatted(.number.precision(.fractionLength(0...1)))) mm")) }
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { camera.append(MetadataRow(label: "Aperture", value: "ƒ/\(f.formatted(.number.precision(.fractionLength(0...1))))")) }
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            camera.append(MetadataRow(label: "Exposure", value: exposure < 1 ? "1/\(Int((1 / exposure).rounded())) s" : "\(exposure) s"))
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { camera.append(MetadataRow(label: "ISO", value: "\(iso)")) }
        if let software = tiff[kCGImagePropertyTIFFSoftware] as? String { camera.append(MetadataRow(label: "Software", value: software)) }
        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any],
           let lat = gps[kCGImagePropertyGPSLatitude] as? Double, let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
            let latRef = gps[kCGImagePropertyGPSLatitudeRef] as? String ?? "N"
            let lonRef = gps[kCGImagePropertyGPSLongitudeRef] as? String ?? "E"
            camera.append(MetadataRow(label: "Location", value: String(format: "%.5f° %@, %.5f° %@", lat, latRef, lon, lonRef)))
        }

        return [MetadataSection(title: "Image", rows: image), MetadataSection(title: "Camera", rows: camera)].filter { !$0.rows.isEmpty }
    }

    private static func media(_ url: URL) async -> [MetadataSection] {
        let asset = AVURLAsset(url: url)
        var rows: [MetadataRow] = []
        if let duration = try? await asset.load(.duration), duration.isNumeric {
            rows.append(MetadataRow(label: "Duration", value: Duration.seconds(duration.seconds).formatted(.time(pattern: duration.seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))))
        }
        if let video = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await video.load(.naturalSize) {
                rows.append(MetadataRow(label: "Dimensions", value: "\(Int(size.width)) × \(Int(size.height))"))
            }
            if let fps = try? await video.load(.nominalFrameRate), fps > 0 {
                rows.append(MetadataRow(label: "Frame rate", value: "\(fps.formatted(.number.precision(.fractionLength(0...2)))) fps"))
            }
            if let bitrate = try? await video.load(.estimatedDataRate), bitrate > 0 {
                rows.append(MetadataRow(label: "Video bitrate", value: "\(Int(bitrate / 1000)) kbps"))
            }
        }
        if let video = try? await asset.loadTracks(withMediaType: .video).first,
           let format = try? await video.load(.formatDescriptions).first {
            rows.append(MetadataRow(label: "Video codec", value: codecName(CMFormatDescriptionGetMediaSubType(format))))
        }
        if let audio = try? await asset.loadTracks(withMediaType: .audio).first {
            if let bitrate = try? await audio.load(.estimatedDataRate), bitrate > 0 {
                rows.append(MetadataRow(label: "Audio bitrate", value: "\(Int(bitrate / 1000)) kbps"))
            }
            if let format = try? await audio.load(.formatDescriptions).first {
                rows.append(MetadataRow(label: "Audio codec", value: codecName(CMFormatDescriptionGetMediaSubType(format))))
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee {
                    let channels = basic.mChannelsPerFrame == 1 ? String(localized: "mono") : basic.mChannelsPerFrame == 2 ? String(localized: "stereo") : String(localized: "\(Int(basic.mChannelsPerFrame)) channels")
                    rows.append(MetadataRow(label: "Audio", value: "\(Int(basic.mSampleRate)) Hz, \(channels)"))
                }
            }
        }
        return rows.isEmpty ? [] : [MetadataSection(title: "Media", rows: rows)]
    }

    /// "avc1" → "H.264 (avc1)" etc.
    static func codecName(_ code: FourCharCode) -> String {
        let chars = [24, 16, 8, 0].map { Character(UnicodeScalar(UInt8((code >> $0) & 0xFF))) }
        let fourCC = String(chars).trimmingCharacters(in: .whitespaces)
        let names = ["avc1": "H.264", "hvc1": "HEVC", "hev1": "HEVC", "ap4h": "ProRes 4444", "apcn": "ProRes 422",
                     "apch": "ProRes 422 HQ", "av01": "AV1", "vp09": "VP9", "mp4v": "MPEG-4", "jpeg": "Motion JPEG",
                     "aac ": "AAC", "lpcm": "PCM", ".mp3": "MP3", "alac": "Apple Lossless", "ac-3": "Dolby Digital",
                     "ec-3": "Dolby Digital Plus", "opus": "Opus", "flac": "FLAC"]
        let key = String(chars)
        return names[key].map { "\($0) (\(fourCC))" } ?? fourCC
    }

    private static func pdf(_ url: URL) -> MetadataSection? {
        guard let document = PDFDocument(url: url) else { return nil }
        var rows = [MetadataRow(label: "Pages", value: "\(document.pageCount)")]
        let attrs = document.documentAttributes ?? [:]
        if let title = attrs[PDFDocumentAttribute.titleAttribute] as? String, !title.isEmpty { rows.append(MetadataRow(label: "Title", value: title)) }
        if let author = attrs[PDFDocumentAttribute.authorAttribute] as? String, !author.isEmpty { rows.append(MetadataRow(label: "Author", value: author)) }
        if let creator = attrs[PDFDocumentAttribute.creatorAttribute] as? String, !creator.isEmpty { rows.append(MetadataRow(label: "Created with", value: creator)) }
        return MetadataSection(title: "Document", rows: rows)
    }

    /// Download source and usage from Spotlight.
    private static func origin(_ url: URL) -> MetadataSection? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL) else { return nil }
        var rows: [MetadataRow] = []
        if let sources = MDItemCopyAttribute(item, kMDItemWhereFroms) as? [String], !sources.isEmpty {
            rows.append(MetadataRow(label: "Downloaded from", value: sources.joined(separator: "\n")))
        }
        if let lastUsed = MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date {
            rows.append(MetadataRow(label: "Last opened", value: lastUsed.formatted(date: .abbreviated, time: .shortened)))
        }
        if let uses = MDItemCopyAttribute(item, "kMDItemUseCount" as CFString) as? Int {
            rows.append(MetadataRow(label: "Times opened", value: "\(uses)"))
        }
        return rows.isEmpty ? nil : MetadataSection(title: "Origin", rows: rows)
    }
}
