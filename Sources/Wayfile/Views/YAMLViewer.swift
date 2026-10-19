import SwiftUI
import Yams

/// YAML as an expandable tree (like JSON), or as highlighted source.
struct YAMLPreview: View {
    let url: URL
    @AppStorage("yaml.showSource") private var showSource = false
    @State private var root: JSONNode?
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $showSource) {
                    Text("Tree").tag(false)
                    Text("Source").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }
            .controlSize(.small)
            .padding(6)
            if showSource {
                CodePreview(url: url, language: "yaml")
            } else if let root {
                List(root.children ?? [root], children: \.children) { node in
                    HStack(spacing: 6) {
                        Text(node.key).fontWeight(.medium)
                        Text(node.summary).foregroundStyle(node.color).lineLimit(1).truncationMode(.tail)
                    }
                    .font(.system(size: 11, design: .monospaced))
                }
                .listStyle(.plain)
            } else if let failure {
                VStack(spacing: 6) {
                    Text("Not valid YAML").font(.headline)
                    Text(failure).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(4)
                    Button("Show Source") { showSource = true }.controlSize(.small)
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: url) {
            let url = url
            let result = await Task.detached { YAMLTree.parse(url) }.value
            switch result {
            case .success(let node): root = node; failure = nil
            case .failure(let error): root = nil; failure = error.localizedDescription
            }
        }
    }
}

enum YAMLTree {
    /// Every document in the file; several documents appear as "[0]", "[1]"…
    static func parse(_ url: URL) -> Result<JSONNode, Error> {
        Result {
            let text = try String(contentsOf: url, encoding: .utf8)
            let documents = try Array(Yams.load_all(yaml: text)).map(normalize)
            let value: Any = documents.count == 1 ? documents[0] : documents
            return JSONNode.build("root", value)
        }
    }

    /// Yams' values → what JSONNode understands (string keys, dates as text, null as NSNull).
    static func normalize(_ value: Any?) -> Any {
        switch value {
        case let dict as [AnyHashable: Any]:
            return Dictionary(dict.map { ("\($0.key.base)", normalize($0.value)) }, uniquingKeysWith: { a, _ in a })
        case let array as [Any?]:
            return array.map(normalize)
        case let date as Date:
            // Plain dates ("2026-10-10") come back as midnight UTC; don't show a time for them.
            let isDateOnly = Int(date.timeIntervalSince1970) % 86_400 == 0
            return isDateOnly ? date.formatted(.iso8601.year().month().day()) : date.formatted(.iso8601)
        case let data as Data:
            return "<\(data.count) bytes>"
        case let int as Int:
            return NSNumber(value: int)
        case let double as Double:
            return NSNumber(value: double)
        case let bool as Bool:
            return NSNumber(value: bool)
        case let string as String:
            return string
        case nil:
            return NSNull()
        default:
            return "\(value!)"
        }
    }
}
