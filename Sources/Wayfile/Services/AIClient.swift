import AppKit
import Foundation
import Observation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Language model used for AI features (plain-language search…): on-device, local (Ollama) or a cloud API.
enum AIProviderKind: String, CaseIterable, Identifiable, Codable {
    case apple, ollama, openAI, anthropic, gemini, claudeCode, codex

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apple: return String(localized: "Apple Intelligence (on-device)")
        case .ollama: return String(localized: "Ollama (local)")
        case .openAI: return String(localized: "OpenAI-compatible API")
        case .anthropic: return String(localized: "Anthropic Claude")
        case .gemini: return String(localized: "Google Gemini")
        case .claudeCode: return String(localized: "Claude subscription (via Claude Code)")
        case .codex: return String(localized: "ChatGPT subscription (via Codex)")
        }
    }

    /// Uses an official command-line tool the user signed in to with their subscription (browser login).
    var usesCLI: Bool { self == .claudeCode || self == .codex }

    var needsKey: Bool { [.openAI, .anthropic, .gemini].contains(self) }
    var hasEndpoint: Bool { [.ollama, .openAI].contains(self) }

    var defaultEndpoint: String {
        switch self {
        case .ollama: return "http://localhost:11434"
        case .openAI: return "https://api.openai.com/v1"
        case .anthropic: return "https://api.anthropic.com"
        case .gemini: return "https://generativelanguage.googleapis.com"
        case .apple, .claudeCode, .codex: return ""
        }
    }

    var defaultModel: String {
        switch self {
        case .ollama: return "llama3.2"
        case .openAI: return "gpt-4o-mini"
        case .anthropic: return "claude-haiku-4-5-20251001"
        case .gemini: return "gemini-2.5-flash"
        case .claudeCode: return "haiku"
        case .codex: return ""
        case .apple: return ""
        }
    }

    var hint: String {
        switch self {
        case .apple: return String(localized: "Runs on this Mac; needs Apple Intelligence turned on in System Settings (macOS 26).")
        case .ollama: return String(localized: "Runs on this Mac with Ollama (ollama.com). Nothing leaves your computer.")
        case .openAI: return String(localized: "OpenAI or any compatible server: OpenRouter, Groq, Together, LM Studio (http://localhost:1234/v1)…")
        case .anthropic: return String(localized: "Uses the Anthropic API with your key.")
        case .gemini: return String(localized: "Uses the Gemini API with your key.")
        case .claudeCode: return String(localized: "Uses your Claude Pro/Max plan through the official Claude Code app — sign in once in the browser, no API key. Answers take a few seconds.")
        case .codex: return String(localized: "Uses your ChatGPT Plus/Pro plan through the official Codex CLI (brew install codex) — sign in once in the browser, no API key.")
        }
    }
}

struct AIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// The chosen provider and its settings; keys live in the Keychain.
@MainActor
@Observable
final class AISettings {
    static let shared = AISettings()

    var provider: AIProviderKind { didSet { save() } }
    /// Per provider, so switching back keeps what was entered.
    var endpoints: [AIProviderKind: String] { didSet { save() } }
    var models: [AIProviderKind: String] { didSet { save() } }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        provider = defaults.string(forKey: "ai.provider").flatMap(AIProviderKind.init(rawValue:)) ?? .apple
        let decode = { (key: String) -> [AIProviderKind: String] in
            let raw = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
            return Dictionary(uniqueKeysWithValues: raw.compactMap { k, v in AIProviderKind(rawValue: k).map { ($0, v) } })
        }
        endpoints = decode("ai.endpoints")
        models = decode("ai.models")
    }

    func endpoint(_ kind: AIProviderKind) -> String {
        let value = endpoints[kind]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? kind.defaultEndpoint : value
    }

    func model(_ kind: AIProviderKind) -> String {
        let value = models[kind]?.trimmingCharacters(in: .whitespaces) ?? ""
        return value.isEmpty ? kind.defaultModel : value
    }

    static func keychainServer(_ kind: AIProviderKind) -> String { "wayfile-ai:\(kind.rawValue)" }

    func apiKey(_ kind: AIProviderKind) -> String? {
        Keychain.password(server: Self.keychainServer(kind), account: "api-key")
    }

    func setAPIKey(_ key: String, for kind: AIProviderKind) throws {
        if key.isEmpty {
            Keychain.delete(server: Self.keychainServer(kind), account: "api-key")
        } else {
            try Keychain.save(password: key, server: Self.keychainServer(kind), account: "api-key", label: "Wayfile AI (\(kind.title))")
        }
    }

    /// Everything a request needs, readable off the main actor.
    var configuration: AIConfiguration {
        AIConfiguration(kind: provider, endpoint: endpoint(provider), model: model(provider), apiKey: apiKey(provider))
    }

    private func save() {
        defaults.set(provider.rawValue, forKey: "ai.provider")
        defaults.set(Dictionary(uniqueKeysWithValues: endpoints.map { ($0.key.rawValue, $0.value) }), forKey: "ai.endpoints")
        defaults.set(Dictionary(uniqueKeysWithValues: models.map { ($0.key.rawValue, $0.value) }), forKey: "ai.models")
    }
}

struct AIConfiguration: Sendable, Equatable {
    var kind: AIProviderKind
    var endpoint: String
    var model: String
    var apiKey: String?
}

/// One-shot chat completions against the configured provider.
enum AIClient {
    /// Asks for a single reply. `json` requests JSON output where the provider supports it.
    static func complete(system: String, user: String, json: Bool = true, configuration: AIConfiguration,
                         session: URLSession = .shared) async throws -> String {
        if configuration.kind == .apple { return try await completeOnDevice(system: system, user: user) }
        if configuration.kind.usesCLI { return try await SubscriptionCLI.complete(system: system, user: user, configuration: configuration) }
        if configuration.kind.needsKey && (configuration.apiKey ?? "").isEmpty {
            throw AIError(message: "Add an API key for \(configuration.kind.title) in Settings → AI.")
        }
        let request = try makeRequest(system: system, user: user, json: json, configuration: configuration)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw AIError(message: errorMessage(data, status: status, kind: configuration.kind)) }
        return try parseResponse(data, kind: configuration.kind)
    }

    static func makeRequest(system: String, user: String, json: Bool, configuration c: AIConfiguration) throws -> URLRequest {
        let base = c.endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        var body: [String: Any]
        var url: URL?
        var headers = ["Content-Type": "application/json"]
        switch c.kind {
        case .ollama:
            url = URL(string: base + "/api/chat")
            body = ["model": c.model, "stream": false,
                    "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
            if json { body["format"] = "json" }
        case .openAI:
            url = URL(string: base + "/chat/completions")
            body = ["model": c.model, "messages": [["role": "system", "content": system], ["role": "user", "content": user]]]
            // Only OpenAI itself is sure to accept response_format; the prompt asks for JSON anyway.
            if json, base.contains("api.openai.com") { body["response_format"] = ["type": "json_object"] }
            if let key = c.apiKey, !key.isEmpty { headers["Authorization"] = "Bearer \(key)" }
        case .anthropic:
            url = URL(string: base + "/v1/messages")
            body = ["model": c.model, "max_tokens": 1024, "system": system, "messages": [["role": "user", "content": user]]]
            headers["x-api-key"] = c.apiKey ?? ""
            headers["anthropic-version"] = "2023-06-01"
        case .gemini:
            let model = c.model.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? c.model
            url = URL(string: base + "/v1beta/models/\(model):generateContent")
            headers["x-goog-api-key"] = c.apiKey ?? ""
            body = ["systemInstruction": ["parts": [["text": system]]], "contents": [["role": "user", "parts": [["text": user]]]]]
            if json { body["generationConfig"] = ["responseMimeType": "application/json"] }
        case .apple, .claudeCode, .codex:
            throw AIError(message: "\(c.kind.title) doesn't use HTTP.")
        }
        guard let url else { throw AIError(message: "“\(c.endpoint)” isn’t a valid address.") }
        var request = URLRequest(url: url, timeoutInterval: c.kind == .ollama ? 120 : 60)
        request.httpMethod = "POST"
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    static func parseResponse(_ data: Data, kind: AIProviderKind) throws -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIError(message: "The model’s answer couldn’t be read.")
        }
        let text: String?
        switch kind {
        case .ollama:
            text = (object["message"] as? [String: Any])?["content"] as? String
        case .openAI:
            text = ((object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String
        case .anthropic:
            text = (object["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        case .gemini:
            let candidate = (object["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any]
            text = (candidate?["parts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
        case .apple, .claudeCode, .codex:
            text = nil
        }
        guard let text, !text.isEmpty else { throw AIError(message: "The model returned an empty answer.") }
        return text
    }

    static func errorMessage(_ data: Data, status: Int, kind: AIProviderKind) -> String {
        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let detail = ((object?["error"] as? [String: Any])?["message"] as? String) ?? (object?["error"] as? String)
        switch status {
        case 401, 403: return "The API key was rejected\(detail.map { ": \($0)" } ?? ".")"
        case 404: return "Not found — check the model name and address\(detail.map { ": \($0)" } ?? ".")"
        case 429: return "Rate limit or quota reached\(detail.map { ": \($0)" } ?? ".")"
        default: return detail ?? "\(kind.title) answered with HTTP \(status)."
        }
    }

    /// Model names Ollama has installed.
    static func ollamaModels(endpoint: String, session: URLSession = .shared) async throws -> [String] {
        guard let url = URL(string: endpoint.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/api/tags") else { return [] }
        let (data, _) = try await session.data(from: url)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return ((object?["models"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
    }

    static var onDeviceAvailability: String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return nil
            case .unavailable(let reason): return "Unavailable: \(reason)"
            }
        }
        #endif
        return "Needs macOS 26 with Apple Intelligence."
    }

    private static func completeOnDevice(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw AIError(message: "Apple Intelligence isn’t available. Turn it on in System Settings, or choose another provider in Settings → AI.")
            }
            let session = LanguageModelSession(instructions: system)
            return try await session.respond(to: user).content
        }
        #endif
        throw AIError(message: "The on-device model needs macOS 26.")
    }
}

/// Claude Code and Codex: official CLIs signed in with a subscription. Wayfile runs them headless
/// with tools disabled, in an empty folder, and reads the final answer.
enum SubscriptionCLI {
    struct Status: Equatable {
        var installed: Bool
        var signedIn: Bool
        var detail: String
    }

    static func executable(for kind: AIProviderKind) -> String? {
        let name = kind == .claudeCode ? "claude" : "codex"
        let home = NSHomeDirectory()
        let candidates = ["/opt/homebrew/bin/\(name)", "/usr/local/bin/\(name)", "\(home)/.local/bin/\(name)",
                          "\(home)/.claude/local/claude", "\(home)/.npm-global/bin/\(name)", "\(home)/.bun/bin/\(name)"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) && ($0.hasSuffix("/" + name)) }
    }

    /// CLIs are often node scripts that need node on PATH (GUI apps get a minimal PATH).
    static var environment: [String: String] {
        let home = NSHomeDirectory()
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.npm-global/bin", "\(home)/.bun/bin"]
        return ["PATH": (extra + [ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]).joined(separator: ":")]
    }

    static func arguments(for kind: AIProviderKind, system: String, user: String, model: String, outputFile: URL) -> [String] {
        switch kind {
        case .claudeCode:
            var args = ["-p", user, "--output-format", "json", "--system-prompt", system, "--tools", ""]
            if !model.isEmpty { args += ["--model", model] }
            return args
        default:
            var args = ["exec", "--skip-git-repo-check", "--sandbox", "read-only", "--output-last-message", outputFile.path]
            if !model.isEmpty { args += ["-m", model] }
            return args + [system + "\n\nRequest: " + user]
        }
    }

    static func complete(system: String, user: String, configuration: AIConfiguration) async throws -> String {
        guard let exe = executable(for: configuration.kind) else {
            throw AIError(message: configuration.kind == .claudeCode
                          ? "Claude Code isn’t installed (brew install --cask claude-code), or choose another provider in Settings → AI."
                          : "Codex isn’t installed (brew install codex), or choose another provider in Settings → AI.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("wayfile-ai-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let outputFile = work.appendingPathComponent("answer.txt")
        let output = await Shell.run(exe, arguments(for: configuration.kind, system: system, user: user, model: configuration.model, outputFile: outputFile),
                                     cwd: work, environment: environment)
        let answer = try parse(kind: configuration.kind, stdout: output.stdout, stderr: output.stderr, status: output.status,
                               lastMessage: try? String(contentsOf: outputFile, encoding: .utf8))
        return answer
    }

    static func parse(kind: AIProviderKind, stdout: String, stderr: String, status: Int32, lastMessage: String?) throws -> String {
        let combined = (stdout + "\n" + stderr).lowercased()
        if combined.contains("not logged in") || combined.contains("please run /login") || combined.contains("codex login")
            || combined.contains("invalid api key") && kind == .claudeCode {
            throw AIError(message: "Sign in to \(kind == .claudeCode ? "Claude Code" : "Codex") first (Settings → AI → Sign In).")
        }
        if kind == .claudeCode {
            if let data = stdout.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if object["is_error"] as? Bool == true {
                    throw AIError(message: (object["result"] as? String) ?? "Claude Code reported an error.")
                }
                if let result = object["result"] as? String, !result.isEmpty { return result }
            }
        } else if let lastMessage, !lastMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return lastMessage
        }
        let text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if status == 0, !text.isEmpty { return text }
        let message = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw AIError(message: message.isEmpty ? "\(kind.title) failed (exit \(status))." : String(message.suffix(400)))
    }

    static func status(for kind: AIProviderKind) async -> Status {
        guard let exe = executable(for: kind) else { return Status(installed: false, signedIn: false, detail: "Not installed") }
        if kind == .claudeCode {
            let output = await Shell.run(exe, ["auth", "status", "--json"], environment: environment)
            let object = (try? JSONSerialization.jsonObject(with: Data(output.stdout.utf8))) as? [String: Any]
            let signedIn = object?["loggedIn"] as? Bool ?? false
            let method = object?["authMethod"] as? String ?? ""
            let detail = signedIn ? (method == "claude.ai" ? String(localized: "Signed in with a Claude subscription") : String(localized: "Signed in (\(method))")) : String(localized: "Not signed in")
            return Status(installed: true, signedIn: signedIn, detail: detail)
        }
        let output = await Shell.run(exe, ["login", "status"], environment: environment)
        let text = (output.stdout + output.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
        let signedIn = output.status == 0 && text.lowercased().contains("logged in") && !text.lowercased().contains("not logged in")
        return Status(installed: true, signedIn: signedIn, detail: signedIn ? text : String(localized: "Not signed in"))
    }

    /// Login arguments: the tool opens the browser itself and prints the link too.
    static func loginArguments(for kind: AIProviderKind) -> [String] {
        kind == .claudeCode ? ["auth", "login", "--claudeai"] : ["login"]
    }

    /// The sign-in link from the tool's output (terminal hyperlink escapes removed).
    static func loginURL(in output: String) -> URL? {
        let cleaned = output.replacingOccurrences(of: "\u{1B}]8;;", with: " ").replacingOccurrences(of: "\u{07}", with: " ")
            .replacingOccurrences(of: "\u{1B}\\", with: " ")
        guard let regex = try? NSRegularExpression(pattern: #"https://[^\s\x{1B}\x{07}]+"#),
              let match = regex.firstMatch(in: cleaned, range: NSRange(cleaned.startIndex..., in: cleaned)),
              let range = Range(match.range, in: cleaned) else { return nil }
        var link = String(cleaned[range])
        // The same link is often printed twice back to back ("…state=abchttps://…").
        if let second = link.range(of: "https://", range: link.index(link.startIndex, offsetBy: 8)..<link.endIndex) {
            link = String(link[..<second.lowerBound])
        }
        return URL(string: link)
    }
}

/// A browser sign-in to Claude Code or Codex, run from Settings without Terminal: the tool opens the
/// sign-in page; Claude then shows a code to paste back here, Codex returns to the app by itself.
@MainActor
@Observable
final class SubscriptionLogin {
    enum State: Equatable {
        case idle
        case waiting(URL?)
        case done
        case failed(String)
    }

    private(set) var state: State = .idle
    let kind: AIProviderKind
    private var process: Process?
    private var input: FileHandle?
    private var output = ""
    private var poll: Task<Void, Never>?
    var onFinish: (() -> Void)?

    init(kind: AIProviderKind) { self.kind = kind }

    /// Claude asks for the code shown in the browser after signing in.
    var asksForCode: Bool { kind == .claudeCode }

    func start() {
        cancel()
        guard let exe = SubscriptionCLI.executable(for: kind) else {
            state = .failed(kind == .claudeCode ? "Install Claude Code first: brew install --cask claude-code" : "Install Codex first: brew install codex")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = SubscriptionCLI.loginArguments(for: kind)
        process.environment = ProcessInfo.processInfo.environment.merging(SubscriptionCLI.environment) { $1 }
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stdout
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard !text.isEmpty else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.received(text) } }
        }
        process.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended(status: finished.terminationStatus) } }
        }
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        state = .waiting(nil)
        // Signing in may finish without the process telling us (e.g. Codex' local callback); watch the status.
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, case .waiting = self.state else { return }
                if await SubscriptionCLI.status(for: self.kind).signedIn { self.finish() }
            }
        }
    }

    /// Sends the code the browser showed (Claude).
    func submit(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let input else { return }
        input.write(Data((trimmed + "\n").utf8))
    }

    /// Opens the sign-in page again (if the browser tab was closed).
    func openLink() {
        if case .waiting(let url?) = state { NSWorkspace.shared.open(url) }
    }

    func cancel() {
        poll?.cancel()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        input = nil
        output = ""
        if state != .done { state = .idle }
    }

    private func received(_ text: String) {
        output += text
        if case .waiting(nil) = state, let url = SubscriptionCLI.loginURL(in: output) { state = .waiting(url) }
        let lower = output.lowercased()
        if lower.contains("login successful") || lower.contains("successfully logged in") || lower.contains("logged in successfully") {
            finish()
        }
    }

    private func ended(status: Int32) {
        guard case .waiting = state else { return }
        Task {
            if await SubscriptionCLI.status(for: kind).signedIn {
                finish()
            } else {
                let tail = output.split(separator: "\n").suffix(2).joined(separator: " ").trimmingCharacters(in: .whitespaces)
                state = .failed(tail.isEmpty ? "Sign-in didn’t finish (exit \(status))." : String(tail.prefix(300)))
            }
        }
    }

    private func finish() {
        poll?.cancel()
        if process?.isRunning == true { process?.terminate() }
        process = nil
        state = .done
        onFinish?()
    }
}
