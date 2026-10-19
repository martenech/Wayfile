import Foundation

/// A shareable script: `Name.wayfilescript`, a JSON file with a manifest and the source.
///
/// The script's header stays the source of truth — the manifest repeats it so a package can be reviewed
/// (and a future community repository can index it) without parsing code. `kind` and `minAPIVersion`
/// leave room for other extension kinds of a later plugin SDK.
struct ScriptPackage: Codable, Equatable {
    static let fileExtension = "wayfilescript"
    static let format = 1
    /// Larger sources are refused on import.
    static let sizeLimit = 1_000_000

    struct Manifest: Codable, Equatable {
        var kind = "script"
        var name: String
        var version: String?
        var description: String?
        var language: String
        var fileName: String
        var permissions: [String]
        var extensions: [String]
        /// Automatic triggers the script declares; an imported script never starts with them on.
        var triggers: [String]
        var minAPIVersion: String
        var exportedBy: String
    }

    var format: Int
    var manifest: Manifest
    var source: String

    enum PackageError: LocalizedError, Equatable {
        case unreadable, newerFormat(Int), unsupportedKind(String), unsupportedLanguage(String), tooLarge, needsNewerAPI(String), mismatch(String)

        var errorDescription: String? {
            switch self {
            case .unreadable: return String(localized: "This isn't a Wayfile script package.")
            case .newerFormat(let format): return String(localized: "The package uses format \(format); this Wayfile reads format \(ScriptPackage.format). Update Wayfile to import it.")
            case .unsupportedKind(let kind): return String(localized: "Packages of kind “\(kind)” aren't supported yet.")
            case .unsupportedLanguage(let language): return String(localized: "Unsupported script language “\(language)”.")
            case .tooLarge: return String(localized: "The script is larger than 1 MB.")
            case .needsNewerAPI(let version): return String(localized: "The script needs scripting API \(version); this Wayfile has \(ScriptAPI.version).")
            case .mismatch(let detail): return String(localized: "The manifest doesn't match the script (\(detail)) — the package may have been altered.")
            }
        }
    }

    init(script: Script, source: String) {
        var triggers: [String] = []
        if let folder = script.triggerFolder {
            triggers.append("New files in " + folder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
        }
        if let minutes = script.scheduleMinutes { triggers.append("Every \(minutes) min") }
        if !script.after.isEmpty { triggers.append("After " + script.after.map(\.rawValue).sorted().joined(separator: ", ")) }
        format = Self.format
        self.source = source
        manifest = Manifest(name: script.name, version: script.version, description: script.summary.isEmpty ? nil : script.summary,
                            language: script.language.rawValue, fileName: script.url.lastPathComponent,
                            permissions: script.permissions.sorted().map(\.rawValue), extensions: script.extensions.sorted(),
                            triggers: triggers, minAPIVersion: script.language == .javascript ? ScriptAPI.version : "1.0",
                            exportedBy: "Wayfile")
    }

    static func export(_ script: Script) throws -> Data {
        let source = try String(contentsOf: script.url, encoding: .utf8)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(ScriptPackage(script: script, source: source))
    }

    /// Decodes and checks a package; the script it describes is parsed from the source, not trusted from the manifest.
    static func read(_ data: Data) throws -> (package: ScriptPackage, script: Script) {
        guard data.count <= sizeLimit * 2 else { throw PackageError.tooLarge }
        guard let package = try? JSONDecoder().decode(ScriptPackage.self, from: data) else { throw PackageError.unreadable }
        guard package.format <= format else { throw PackageError.newerFormat(package.format) }
        guard package.manifest.kind == "script" else { throw PackageError.unsupportedKind(package.manifest.kind) }
        guard let language = Script.Language(rawValue: package.manifest.language) else { throw PackageError.unsupportedLanguage(package.manifest.language) }
        guard package.source.utf8.count <= sizeLimit else { throw PackageError.tooLarge }
        guard compare(package.manifest.minAPIVersion, ScriptAPI.version) != .orderedDescending else { throw PackageError.needsNewerAPI(package.manifest.minAPIVersion) }
        let fileName = safeFileName(package.manifest.fileName, language: language)
        guard let script = Script(url: URL(fileURLWithPath: "/imported").appendingPathComponent(fileName), text: package.source) else {
            throw PackageError.unsupportedLanguage(package.manifest.language)
        }
        // What the review shows must be what will run: permissions are compared with the source's header.
        if Set(package.manifest.permissions) != Set(script.permissions.map(\.rawValue)) { throw PackageError.mismatch("permissions") }
        return (package, script)
    }

    /// A plain file name with the language's extension: no folders, no hidden files.
    static func safeFileName(_ name: String, language: Script.Language) -> String {
        var base = (name as NSString).lastPathComponent
        base = (base as NSString).deletingPathExtension
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while base.hasPrefix(".") { base.removeFirst() }
        if base.trimmingCharacters(in: .whitespaces).isEmpty { base = "Imported Script" }
        return base + "." + language.fileExtension
    }

    /// Writes the script into the Scripts folder under a free name.
    static func install(_ package: ScriptPackage, language: Script.Language, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = FileOps.uniqueURL(folder.appendingPathComponent(safeFileName(package.manifest.fileName, language: language)))
        try package.source.write(to: url, atomically: true, encoding: .utf8)
        if language.isExecutableFile { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path) }
        return url
    }

    /// Numeric comparison of "1.10" vs "1.2".
    static func compare(_ a: String, _ b: String) -> ComparisonResult {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
