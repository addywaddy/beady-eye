import SwiftUI

/// A status line at the bottom of the sidebar: Dolt branch, remote, push/pull, and uncommitted changes.
struct DoltBar: View {
    @Environment(Store.self) private var store
    @State private var showAdd = false
    @State private var confirm: Action?

    enum Action: Identifiable { case push, pull; var id: Self { self } }

    var body: some View {
        if let d = store.dolt {
            VStack(alignment: .leading, spacing: 6) {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(d.branch).fontWeight(.medium)
                    Text(String(d.commit.prefix(7))).foregroundStyle(.secondary).monospaced()
                    Spacer()
                    if let busy = store.doltBusy { ProgressView().controlSize(.small).help(busy) }
                }
                .font(.caption)
                if d.uncommitted > 0 {
                    HStack {
                        Text("\(d.uncommitted) uncommitted").foregroundStyle(.orange)
                        Spacer()
                        Button("Commit") { store.doltCommit() }.controlSize(.small)
                    }.font(.caption)
                }
                if let remote = store.remotes.first {
                    HStack(spacing: 6) {
                        Menu {
                            ForEach(store.remotes) { r in
                                Menu("\(r.name)  \(r.url)") { Button("Remove", role: .destructive) { store.removeRemote(r.name) } }
                            }
                            Divider()
                            Button("Add Remote…") { showAdd = true }
                        } label: { Label(remote.name, systemImage: "cloud") }
                            .menuStyle(.borderlessButton).fixedSize()
                        Spacer()
                        Button("Pull") { confirm = .pull }
                        Button("Push") { confirm = .push }
                    }
                    .controlSize(.small).font(.caption)
                    .disabled(store.doltBusy != nil)
                } else {
                    HStack {
                        Text("No remote").foregroundStyle(.secondary)
                        Spacer()
                        Button("Add Remote…") { showAdd = true }.controlSize(.small)
                    }.font(.caption)
                }
                if let e = store.doltError {
                    Text(e).font(.caption2).foregroundStyle(.red).textSelection(.enabled).lineLimit(6)
                }
            }
            .padding(.horizontal, 10).padding(.bottom, 8)
            .background(.bar)
            .sheet(isPresented: $showAdd) { AddRemoteSheet() }
            .confirmationDialog(confirm == .push ? "Push to \(store.remotes.first?.name ?? "remote")?" : "Pull from \(store.remotes.first?.name ?? "remote")?",
                                isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), titleVisibility: .visible) {
                if confirm == .push { Button("Push") { store.doltPush() } } else { Button("Pull") { store.doltPull() } }
            } message: {
                Text(confirm == .push ? "This publishes your issue data to the remote." : "This merges the remote's issue data into this project.")
            }
        }
    }
}

struct AddRemoteSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = "origin"
    @State private var url = ""
    @State private var allowGitOrigin = false
    @State private var error: String?
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Dolt Remote").font(.headline)
            TextField("Name", text: $name)
            TextField("URL (e.g. https://doltremoteapi.dolthub.com/user/repo)", text: $url)
            if let error {
                Text(error).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                if error.localizedCaseInsensitiveContains("git origin") {
                    Toggle("Allow a URL that matches the git origin", isOn: $allowGitOrigin)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") {
                    working = true
                    Task {
                        error = await store.addRemote(name.trimmingCharacters(in: .whitespaces), url.trimmingCharacters(in: .whitespaces), allowGitOrigin: allowGitOrigin)
                        working = false
                        if error == nil { dismiss() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || url.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
        }
        .textFieldStyle(.roundedBorder)
        .padding(20).frame(width: 440)
    }
}
