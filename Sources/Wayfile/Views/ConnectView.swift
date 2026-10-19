import AppKit
import SwiftUI

/// Connect to Server: address + optional credentials, saved servers, servers found on the network.
struct ConnectView: View {
    let state: WindowState
    @State private var address: String
    @State private var username = ""
    @State private var password = ""
    @State private var savePassword = true
    @State private var connecting = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    private var store: ServerStore { .shared }

    init(state: WindowState, address: String = "") {
        self.state = state
        _address = State(initialValue: address)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect to Server").font(.title3.weight(.semibold))
            Form {
                TextField("Address", text: $address, prompt: Text("smb://nas.local/share · https://dav.example.com"))
                    .onSubmit(connect)
                TextField("User name", text: $username, prompt: Text("Optional — asks when needed"))
                SecureField("Password", text: $password)
                Toggle("Remember password in Keychain", isOn: $savePassword)
                    .disabled(username.isEmpty || password.isEmpty)
            }
            .formStyle(.columns)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.callout)
            }
            HStack(alignment: .top, spacing: 14) {
                list("Saved", empty: "Servers you connect to appear here.") {
                    ForEach(store.servers) { server in
                        row(server.name, detail: ServerAddress.kind(server.url) + (server.username.map { " · \($0)" } ?? ""), symbol: "server.rack") {
                            address = server.url.absoluteString
                            username = server.username ?? ""
                            password = ""
                        }
                        .contextMenu {
                            Button("Remove", role: .destructive) { store.remove(server) }
                        }
                    }
                }
                list("On This Network", empty: "Looking for servers…") {
                    ForEach(store.discovered) { found in
                        row(found.name, detail: found.kind, symbol: "desktopcomputer") {
                            address = found.url?.absoluteString ?? ""
                        }
                    }
                }
            }
            .frame(height: 170)
            HStack {
                Text("SMB, AFP, NFS and WebDAV shares are mounted by macOS and browse like any folder.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if connecting { ProgressView().controlSize(.small) }
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect", action: connect)
                    .keyboardShortcut(.defaultAction)
                    .disabled(ServerAddress.normalize(address) == nil || connecting)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear { store.startDiscovery() }
    }

    private func list<Content: View>(_ title: String, empty: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key: title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            List { content() }
                .listStyle(.bordered(alternatesRowBackgrounds: false))
                .overlay {
                    if title == "Saved" ? store.servers.isEmpty : store.discovered.isEmpty {
                        Text(empty).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).padding()
                    }
                }
        }
    }

    private func row(_ name: String, detail: String, symbol: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(name).lineLimit(1)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .onTapGesture(count: 2) { action(); connect() }
    }

    private func connect() {
        guard let url = ServerAddress.normalize(address), !connecting else { return }
        connecting = true
        error = nil
        Task {
            do {
                let mount = try await store.connect(url, username: username.isEmpty ? nil : username,
                                                    password: password.isEmpty ? nil : password,
                                                    savePassword: savePassword)
                state.activePane.navigate(to: .folderAt(mount))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            connecting = false
        }
    }
}
