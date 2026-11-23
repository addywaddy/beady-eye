import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store
    @Binding var showNew: Bool

    var body: some View {
        @Bindable var store = store
        Group {
            if store.active == nil {
                WelcomeView()
            } else {
                Group {
                    if store.viewMode == .list {
                        NavigationSplitView {
                            Sidebar().navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
                        } content: {
                            IssueList().navigationSplitViewColumnWidth(min: 300, ideal: 380)
                        } detail: {
                            detailPane
                        }
                    } else {
                        NavigationSplitView {
                            Sidebar().navigationSplitViewColumnWidth(min: 160, ideal: 180, max: 240)
                        } detail: {
                            Group {
                                if store.viewMode == .board { BoardView() } else { GraphView() }
                            }
                            .inspector(isPresented: Binding(
                                get: { store.selection != nil },
                                set: { if !$0 { store.selection = nil } })
                            ) {
                                detailPane.inspectorColumnWidth(min: 320, ideal: 400, max: 560)
                            }
                        }
                    }
                }
                .navigationTitle(store.active?.name ?? "Beady Eye")
                .searchable(text: $store.search, prompt: "Search issues")
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        Picker("View", selection: $store.viewMode) {
                            ForEach(ViewMode.allCases) { Label($0.label, systemImage: $0.symbol).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
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

extension ContentView {
    @ViewBuilder var detailPane: some View {
        if let issue = store.detail {
            IssueDetail(issue: issue).id(issue.id)
        } else if store.selection != nil {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView("No Issue Selected", systemImage: "circle.dotted", description: Text("Pick an issue from the list."))
        }
    }
}

/// Background refresh failures. Lives inside each content column (not around the split view),
/// otherwise it slides under the window toolbar and the sidebar.
struct RefreshBanner: View {
    @Environment(Store.self) private var store
    var body: some View {
        if let e = store.refreshError {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(e).font(.callout).lineLimit(4).textSelection(.enabled)
                Spacer(minLength: 8)
                Button("Retry") { Task { await store.refresh() } }
            }
            .padding(10)
            .background(.regularMaterial)
            .background(.orange.opacity(0.15))
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}

struct WelcomeView: View {
    @Environment(Store.self) private var store
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "eye.circle").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Beady Eye").font(.largeTitle.bold())
            Text("A native front end for the bd issue tracker.").foregroundStyle(.secondary)
            Button("Add Connection…") { store.addConnectionWithPanel() }.buttonStyle(.borderedProminent).controlSize(.large)
            if !store.connections.isEmpty {
                Divider().frame(width: 220)
                ForEach(store.connections) { c in
                    Button("\(c.name)  —  \(c.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))") { store.activeID = c.id }
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
        .safeAreaInset(edge: .top) { ConnectionSwitcher() }
    }
}

struct ConnectionSwitcher: View {
    @Environment(Store.self) private var store
    @State private var renaming = false
    @State private var newName = ""
    @State private var confirmRemove = false

    var body: some View {
        Menu {
            ForEach(store.connections) { c in
                Button { store.activeID = c.id } label: {
                    if c.id == store.activeID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            Divider()
            Button("Add Connection…") { store.addConnectionWithPanel() }
            Button("Rename…") { newName = store.active?.name ?? ""; renaming = true }
            Button("Remove “\(store.active?.name ?? "")”…", role: .destructive) { confirmRemove = true }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "externaldrive.connected.to.line.below")
                Text(store.active?.name ?? "No connection").lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden)
        .help(store.active?.path ?? "")
        .padding(.horizontal, 10).padding(.vertical, 6)
        .alert("Rename Connection", isPresented: $renaming) {
            TextField("Name", text: $newName)
            Button("Rename") { if let id = store.activeID { store.rename(id, to: newName) } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this connection?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { if let id = store.activeID { store.remove(id) } }
        } message: { Text("The project folder and its issues are not touched. You can add it again later.") }
    }
}

struct IssueList: View {
    @Environment(Store.self) private var store
    var body: some View {
        @Bindable var store = store
        List(store.visible, selection: $store.selection) { issue in
            IssueRow(issue: issue, ready: store.readyIDs.contains(issue.id)).tag(issue.id)
        }
        .safeAreaInset(edge: .top, spacing: 0) { RefreshBanner() }
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
