import AppKit
import SwiftUI

struct AskAITarget: Codable, Hashable {
    var urls: [URL]
}

/// "Ask AI" window: a conversation about the chosen files or folder, answered by the model from Settings → AI.
struct AskAIView: View {
    let target: AskAITarget

    struct Exchange: Identifiable {
        let id = UUID()
        let question: String
        var answer: String?
        var error: String?
    }

    @State private var context: AIContext.Built?
    @State private var exchanges: [Exchange] = []
    @State private var question = ""
    @State private var busy = false
    @FocusState private var focused: Bool
    @Environment(\.openSettings) private var openSettings

    private var isFolder: Bool { target.urls.count == 1 && FileSystem.isDirectory(target.urls[0]) && !FileSystem.isPackage(target.urls[0]) }

    private var suggestions: [String] {
        if isFolder {
            return ["What's in this folder?", "Summarize what this project or folder is about", "What could I clean up or delete here?", "Which files are the largest or oldest?"]
        }
        let ext = target.urls.first?.pathExtension.lowercased() ?? ""
        if target.urls.count > 1 { return ["Summarize these files", "How do these files differ?", "What do these files have in common?"] }
        if ["swift", "js", "ts", "py", "rb", "go", "rs", "java", "kt", "c", "cpp", "h", "m", "php", "sh", "css", "html"].contains(ext) {
            return ["Explain this code", "Are there bugs or risky parts?", "Summarize what it does"]
        }
        if ["csv", "tsv", "json", "log"].contains(ext) { return ["Summarize this data", "What stands out or looks wrong?", "Explain the structure"] }
        return ["Summarize this", "List the key points", "What are the important dates, amounts or names?"]
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if exchanges.isEmpty { suggestionList }
                        ForEach(exchanges) { exchange in
                            exchangeView(exchange).id(exchange.id)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: exchanges.count) { if let last = exchanges.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } } }
            }
            Divider()
            HStack(spacing: 8) {
                TextField(isFolder ? String(localized: "Ask about this folder…") : target.urls.count == 1 ? String(localized: "Ask about this file…") : String(localized: "Ask about these files…"), text: $question, axis: .vertical)
                    .lineLimit(1...4)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { ask(question) }
                if busy { ProgressView().controlSize(.small) }
                Button("Ask") { ask(question) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || busy || context == nil)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 460)
        .navigationTitle("Ask AI — " + (target.urls.count == 1 ? target.urls[0].lastPathComponent : "\(target.urls.count) items"))
        .task {
            let urls = target.urls
            context = await Task.detached { AIContext.build(for: urls) }.value
            focused = true
            #if DEBUG
            if let question = ProcessInfo.processInfo.environment["WAYFILE_ASKAI_QUESTION"] { ask(question) }
            #endif
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                ForEach(target.urls.prefix(4), id: \.self) { url in
                    Label { Text(url.lastPathComponent).lineLimit(1) } icon: {
                        Image(nsImage: IconCache.icon(for: url)).resizable().frame(width: 16, height: 16)
                    }
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(.quaternary, in: Capsule())
                }
                if target.urls.count > 4 { Text("+\(target.urls.count - 4)").foregroundStyle(.secondary) }
                Spacer()
                Button(action: openAISettings) {
                    Label(AISettings.shared.provider.title, systemImage: "sparkles")
                }
                .buttonStyle(.borderless)
                .help("Change the model in Settings → AI")
            }
            if let context {
                Text(contextNote(context)).font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Reading…").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private func contextNote(_ context: AIContext.Built) -> String {
        let provider = AISettings.shared.provider
        let local = provider == .apple || provider == .ollama
        var parts: [String] = []
        let files = context.included.filter { !$0.hasSuffix("/") }.count
        if context.included.contains(where: { $0.hasSuffix("/") }) { parts.append(String(localized: "Folder listing")) }
        if files > 0 { parts.append(String(localized: "text of \(files) files")) }
        if !context.describedOnly.isEmpty { parts.append(String(localized: "\(context.describedOnly.count) described by name only (not text)")) }
        if context.truncated { parts.append(String(localized: "long content shortened")) }
        parts.append(local ? String(localized: "stays on this Mac") : String(localized: "is sent to \(provider.title)"))
        return parts.joined(separator: " · ")
    }

    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 8) {
            (isFolder ? Text("Ask anything about this folder, or start with:")
                : target.urls.count == 1 ? Text("Ask anything about this file, or start with:") : Text("Ask anything about these files, or start with:"))
                .foregroundStyle(.secondary)
            ForEach(suggestions, id: \.self) { suggestion in
                Button { ask(suggestion) } label: {
                    Label(suggestion, systemImage: "sparkle").frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.bordered)
                .disabled(busy || context == nil)
            }
        }
    }

    private func exchangeView(_ exchange: Exchange) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(exchange.question)
                .fontWeight(.medium)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.themeAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            if let answer = exchange.answer {
                MarkdownBlocks(text: answer)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(answer, forType: .string)
                    } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else if let error = exchange.error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    Button("Open Settings → AI", action: openAISettings).buttonStyle(.link).font(.caption)
                }
            } else {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private func ask(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !busy, let context else { return }
        question = ""
        let history = exchanges.compactMap { e in e.answer.map { (question: e.question, answer: $0) } }
        exchanges.append(Exchange(question: trimmed))
        let index = exchanges.count - 1
        let configuration = AISettings.shared.configuration
        busy = true
        Task {
            do {
                let answer = try await AIClient.complete(system: AIContext.instructions,
                                                         user: AIContext.prompt(context: context, history: history, question: trimmed),
                                                         json: false, configuration: configuration)
                exchanges[index].answer = answer.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                exchanges[index].error = error.localizedDescription
            }
            busy = false
        }
    }

    private func openAISettings() {
        UserDefaults.standard.set("ai", forKey: "settings.tab")
        openSettings()
    }
}

/// Enough Markdown for model answers: headings, bullet and numbered lists, code blocks, inline styles.
struct MarkdownBlocks: View {
    let text: String

    enum Block: Hashable {
        case heading(String, level: Int)
        case bullet(String, indent: Int)
        case numbered(String, String)
        case code(String)
        case paragraph(String)
    }

    static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var code: [String]?
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { flush(); continue }
            if let hashes = line.firstIndex(where: { $0 != "#" }), line.hasPrefix("#"), line[hashes] == " " {
                flush()
                blocks.append(.heading(String(line[hashes...]).trimmingCharacters(in: .whitespaces), level: line.distance(from: line.startIndex, to: hashes)))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                flush()
                let indent = raw.prefix(while: { $0 == " " }).count / 2
                blocks.append(.bullet(String(line.dropFirst(2)), indent: indent))
            } else if let dot = line.firstIndex(of: "."), line[..<dot].allSatisfy(\.isNumber), !line[..<dot].isEmpty,
                      line[line.index(after: dot)...].hasPrefix(" ") {
                flush()
                blocks.append(.numbered(String(line[..<dot]), String(line[line.index(dot, offsetBy: 2)...])))
            } else {
                paragraph.append(line)
            }
        }
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return blocks
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let text, let level):
                    Text(inline(text)).font(level <= 1 ? .title3.weight(.semibold) : .headline).padding(.top, 4)
                case .bullet(let text, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(text))
                    }
                    .padding(.leading, CGFloat(indent) * 16)
                case .numbered(let number, let text):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(number).").foregroundStyle(.secondary).monospacedDigit()
                        Text(inline(text))
                    }
                case .code(let code):
                    Text(code)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                case .paragraph(let text):
                    Text(inline(text))
                }
            }
        }
    }

    private func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text)
    }
}
