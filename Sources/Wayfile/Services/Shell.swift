import Foundation

struct ShellError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Shell {
    struct Output {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    static func run(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String] = [:]) async -> Output {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                if let cwd { process.currentDirectoryURL = cwd }
                if !environment.isEmpty {
                    process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
                }
                let out = Pipe()
                let err = Pipe()
                process.standardOutput = out
                process.standardError = err
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: Output(status: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                let errData = err.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self)
                ))
            }
        }
    }

    /// Runs a command and throws with its stderr when it exits non-zero.
    @discardableResult
    static func check(_ executable: String, _ arguments: [String], cwd: URL? = nil, environment: [String: String] = [:]) async throws -> String {
        let output = await run(executable, arguments, cwd: cwd, environment: environment)
        guard output.status == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw ShellError(message: message.isEmpty ? "\(executable) failed (\(output.status))" : message)
        }
        return output.stdout
    }
}

enum Spotlight {
    static let resultLimit = 2000

    static func files(taggedWith tag: String) async -> [URL] {
        let escaped = tag.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let output = await Shell.run("/usr/bin/mdfind", ["kMDItemUserTags == '\(escaped)'"])
        return urls(from: output.stdout)
    }

    static func recentFiles(days: Int = 14, limit: Int = 24) async -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let query = "kMDItemLastUsedDate >= $time.today(-\(days)) && kMDItemContentType != public.folder"
        let output = await Shell.run("/usr/bin/mdfind", ["-onlyin", home.path, query])
        let library = home.appendingPathComponent("Library").path + "/"
        let candidates = urls(from: output.stdout).filter {
            !$0.path.hasPrefix(library) && !$0.pathComponents.contains { $0.hasPrefix(".") }
        }
        let dated: [(URL, Date)] = candidates.compactMap { url in
            guard let date = try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate else { return nil }
            return (url, date)
        }
        return dated.sorted { $0.1 > $1.1 }.prefix(limit).map(\.0)
    }

    private static func urls(from output: String) -> [URL] {
        output.split(separator: "\n").prefix(resultLimit).map { URL(fileURLWithPath: String($0)) }
    }
}
