import SwiftUI

/// Settings → AI: which model answers (on-device, Ollama, API key, or a Claude/ChatGPT subscription).
struct AISettingsView: View {
    @Bindable private var settings = AISettings.shared
    @State private var keyText = ""
    @State private var testing = false
    @State private var testResult: String?
    @State private var ollamaModels: [String] = []
    @State private var cliStatus: SubscriptionCLI.Status?
    @State private var login: SubscriptionLogin?
    @State private var code = ""

    private var kind: AIProviderKind { settings.provider }

    var body: some View {
        Form {
            Picker("Provider", selection: $settings.provider) {
                Section("Subscription — sign in in the browser") {
                    Text(AIProviderKind.claudeCode.title).tag(AIProviderKind.claudeCode)
                    Text(AIProviderKind.codex.title).tag(AIProviderKind.codex)
                }
                Section("On this Mac") {
                    Text(AIProviderKind.apple.title).tag(AIProviderKind.apple)
                    Text(AIProviderKind.ollama.title).tag(AIProviderKind.ollama)
                }
                Section("API key") {
                    Text(AIProviderKind.openAI.title).tag(AIProviderKind.openAI)
                    Text(AIProviderKind.anthropic.title).tag(AIProviderKind.anthropic)
                    Text(AIProviderKind.gemini.title).tag(AIProviderKind.gemini)
                }
            }
            Text(kind.hint).font(.caption).foregroundStyle(.secondary)

            if kind.usesCLI { subscriptionSection }
            if kind == .apple {
                LabeledContent("Status", value: AIClient.onDeviceAvailability ?? "Available")
            }
            if kind.hasEndpoint {
                TextField("Address", text: Binding(get: { settings.endpoints[kind] ?? "" }, set: { settings.endpoints[kind] = $0 }),
                          prompt: Text(kind.defaultEndpoint))
            }
            if kind != .apple {
                modelField
            }
            if kind.needsKey || kind == .openAI {
                SecureField("API key", text: $keyText, prompt: Text(settings.apiKey(kind) == nil ? (kind == .openAI ? "Not needed for local servers" : "Paste your key") : String(localized: "Saved in Keychain — paste to replace")))
                    .onSubmit(saveKey)
                HStack {
                    Button("Save Key", action: saveKey).disabled(keyText.isEmpty)
                    if settings.apiKey(kind) != nil {
                        Button("Remove Key", role: .destructive) { try? settings.setAPIKey("", for: kind); keyText = "" }
                    }
                }
            }
            HStack {
                Button("Test") { test() }.disabled(testing)
                if testing { ProgressView().controlSize(.small) }
                if let testResult {
                    Text(testResult).font(.callout).foregroundStyle(testResult.hasPrefix("✓") ? .green : .red).lineLimit(3)
                }
            }
            Text("Used for “Ask AI” in search. Requests go only to the provider you choose; API keys stay in your Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .task(id: kind) { await refresh() }
        .onChange(of: kind) { keyText = ""; testResult = nil; login?.cancel(); login = nil; code = "" }
    }

    @ViewBuilder
    private var modelField: some View {
        if kind == .ollama && !ollamaModels.isEmpty {
            Picker("Model", selection: Binding(get: { settings.model(kind) }, set: { settings.models[kind] = $0 })) {
                ForEach(ollamaModels, id: \.self) { Text($0).tag($0) }
                if !ollamaModels.contains(settings.model(kind)) { Text(settings.model(kind)).tag(settings.model(kind)) }
            }
        } else {
            TextField("Model", text: Binding(get: { settings.models[kind] ?? "" }, set: { settings.models[kind] = $0 }),
                      prompt: Text(kind.defaultModel.isEmpty ? String(localized: "Default") : kind.defaultModel))
        }
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        LabeledContent("Account") {
            HStack {
                if let cliStatus {
                    Image(systemName: cliStatus.signedIn ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(cliStatus.signedIn ? .green : .secondary)
                    Text(cliStatus.detail)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
        if cliStatus?.installed == false {
            Text(kind == .claudeCode ? String(localized: "Install Claude Code first: brew install --cask claude-code") : String(localized: "Install Codex first: brew install codex"))
                .font(.callout).foregroundStyle(.orange).textSelection(.enabled)
        } else if let login, case .waiting(let url) = login.state {
            VStack(alignment: .leading, spacing: 8) {
                Label("Finish signing in in your browser.", systemImage: "safari")
                if login.asksForCode {
                    Text("After you approve, the page shows a code — paste it here:").font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Code", text: $code).textFieldStyle(.roundedBorder).onSubmit { login.submit(code: code) }
                        Button("Continue") { login.submit(code: code) }.disabled(code.isEmpty)
                    }
                }
                HStack {
                    if url != nil { Button("Open Sign-In Page Again") { login.openLink() } }
                    Button("Cancel") { login.cancel(); self.login = nil }
                }
                .controlSize(.small)
            }
        } else {
            HStack {
                Button(cliStatus?.signedIn == true ? String(localized: "Sign In with Another Account…") : String(localized: "Sign In…")) { startLogin() }
                if case .failed(let message) = login?.state { Text(message).font(.caption).foregroundStyle(.red).lineLimit(2) }
            }
        }
    }

    private func startLogin() {
        let session = SubscriptionLogin(kind: kind)
        session.onFinish = { Task { await refresh(); login = nil; code = "" } }
        login = session
        code = ""
        session.start()
    }

    private func refresh() async {
        if kind.usesCLI {
            cliStatus = nil
            cliStatus = await SubscriptionCLI.status(for: kind)
        }
        if kind == .ollama {
            ollamaModels = (try? await AIClient.ollamaModels(endpoint: settings.endpoint(.ollama))) ?? []
        }
    }

    private func saveKey() {
        do {
            try settings.setAPIKey(keyText.trimmingCharacters(in: .whitespacesAndNewlines), for: kind)
            keyText = ""
            testResult = "Key saved."
        } catch {
            testResult = error.localizedDescription
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let configuration = settings.configuration
        Task {
            do {
                let started = Date()
                let answer = try await AIClient.complete(system: "Reply with the JSON object {\"ok\": true} and nothing else.", user: "ping",
                                                         configuration: configuration)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                testResult = answer.contains("ok") ? "✓ Works (\(seconds) s)" : "✓ Answered in \(seconds) s: \(answer.prefix(60))"
            } catch {
                testResult = error.localizedDescription
            }
            testing = false
        }
    }
}

/// "Ask AI to Find Files…": describe what you're looking for in your own words.
struct AskAISheet: View {
    let state: WindowState
    var folder: URL?
    @State private var request = ""
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(folder.map { "Search “\($0.lastPathComponent)” with AI" } ?? String(localized: "Ask AI to Find Files"), systemImage: "sparkles")
                .font(.title3.weight(.semibold))
            TextField("e.g. photos from last summer on the desktop, invoices over 1 MB", text: $request, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .onSubmit(ask)
            HStack {
                Text("Model: \(AISettings.shared.provider.title)").font(.caption).foregroundStyle(.secondary)
                Button("Change…") {
                    UserDefaults.standard.set("ai", forKey: "settings.tab")
                    openSettings()
                }
                .buttonStyle(.link)
                .font(.caption)
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Search", action: ask).keyboardShortcut(.defaultAction)
                    .disabled(request.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func ask() {
        state.askAI(request, in: folder)
        dismiss()
    }
}
