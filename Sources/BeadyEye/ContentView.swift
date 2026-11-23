import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Binding var showNew: Bool

    var body: some View {
        @Bindable var store = store
        Group {
            if store.workspace == nil {
                WelcomeView()
            } else {
                NavigationSplitView {
                    Sidebar()
                        .navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
                } content: {
                    IssueList()
                        .navigationSplitViewColumnWidth(min: 300, ideal: 380)
                } detail: {
                    if let issue = store.detail {
                        IssueDetail(issue: issue).id(issue.id)
                    } else {
                        ContentUnavailableView("No Issue Selected", systemImage: "circle.dotted", description: Text("Pick an issue from the list."))
                    }
                }
                .navigationTitle(store.workspace?.lastPathComponent ?? "Beady Eye")
                .searchable(text: $store.search, prompt: "Search issues")
                .toolbar {
                    ToolbarItem { Button { showNew = true } label: { Label("New Issue", systemImage: "plus") } }
                    ToolbarItem { Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
                }
            }
        }
        .sheet(isPresented: $showNew) { NewIssueSheet() }
        .alert("bd error", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
    }
}

struct WelcomeView: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.circle").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Beady Eye").font(.largeTitle.bold())
            Text("A native front end for the bd issue tracker.").foregroundStyle(.secondary)
            Button("Open Project…") { store.chooseWorkspace() }.buttonStyle(.borderedProminent).controlSize(.large)
            if !store.recents.isEmpty {
                Divider().frame(width: 220)
                ForEach(store.recents, id: \.self) { url in
                    Button(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) { store.workspace = url }
                        .buttonStyle(.link)
                }
            }
        }
        .padding(40).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct Sidebar: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        List(selection: $store.filter) {
            Section("Issues") {
                ForEach(Filter.allCases) { f in
                    Label(f.label, systemImage: f.symbol)
                        .badge(store.count(f))
                        .tag(f)
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct IssueList: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        List(store.visible, selection: $store.selection) { issue in
            IssueRow(issue: issue, ready: store.readyIDs.contains(issue.id)).tag(issue.id)
        }
        .overlay {
            if store.visible.isEmpty {
                ContentUnavailableView(store.search.isEmpty ? "Nothing here" : "No Results",
                                       systemImage: store.search.isEmpty ? "tray" : "magnifyingglass")
            }
        }
    }
}

struct IssueRow: View {
    let issue: Issue
    let ready: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIcon(status: issue.status).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(issue.title).lineLimit(2).strikethrough(issue.isClosed).foregroundStyle(issue.isClosed ? .secondary : .primary)
                HStack(spacing: 8) {
                    Text(issue.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    TypeBadge(type: issue.issueType)
                    if ready { Image(systemName: "bolt.fill").font(.caption).foregroundStyle(.green) }
                    if let a = issue.assignee, !a.isEmpty { Text(a).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Spacer(minLength: 0)
            PriorityBadge(priority: issue.priority)
        }
        .padding(.vertical, 2)
    }
}
