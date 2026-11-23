import SwiftUI

struct ContentView: View {
    @Environment(Store.self) private var store

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
                            // A plain resizable side panel, the same kind of container the list view's detail
                            // column is, rather than SwiftUI's .inspector.
                            SidePanelLayout(showPanel: store.selection != nil) {
                                if store.viewMode == .board { BoardView() } else { GraphView() }
                            } panel: {
                                detailPane
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
                    if store.viewMode == .board {
                        ToolbarItem {
                            Toggle(isOn: $store.showEpicsOnBoard) { Label("Epics", systemImage: "square.stack.3d.up") }
                                .help(store.showEpicsOnBoard ? "Hide epics on the board" : "Show epics on the board")
                        }
                    }
                    ToolbarItem { Button { store.presentNewIssue() } label: { Label("New Issue", systemImage: "plus") } }
                    ToolbarItem { Button { Task { await store.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") } }
                }
            }
        }
        .sheet(isPresented: $store.showNewIssue) { NewIssueSheet() }
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
        List(selection: $store.sidebar) {
            Section("Statuses") {
                ForEach(store.statuses) { st in
                    Button { store.toggleStatus(st.name) } label: {
                        HStack {
                            Label(st.label, systemImage: st.symbol)
                            Spacer()
                            Text("\(store.issues(for: store.sidebar).filter { $0.status == st.name }.count)").foregroundStyle(.secondary)
                            Image(systemName: "checkmark").opacity(store.statusFilter.contains(st.name) ? 1 : 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Show only issues whose status is “\(st.name)” (\(st.category)). Select several to combine.")
                }
            }
            if !store.epics.isEmpty {
                Section("Epics") {
                    ForEach(store.epics) { e in
                        let p = store.progress(of: e.id)
                        Button { store.toggleEpic(e.id) } label: {
                            HStack {
                                Label(e.title, systemImage: "square.stack.3d.up").lineLimit(1)
                                Spacer()
                                if p.total > 0 { Text("\(p.done)/\(p.total)").foregroundStyle(.secondary) }
                                Image(systemName: "checkmark").opacity(store.epicFilter.contains(e.id) ? 1 : 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Show only this epic's issues. Select several to combine.")
                    }
                }
            }
            Section("Assignees") {
                if let me = store.me {
                    AssigneeRow(name: me, filterKey: me, title: "Me (\(me))", subtitle: store.meEmail,
                                symbol: "person.crop.circle.fill")
                }
                ForEach(store.otherAssignees, id: \.self) { a in
                    AssigneeRow(name: a, filterKey: a, title: a, subtitle: nil, symbol: "person")
                }
                AssigneeRow(name: "", filterKey: "", title: "Unassigned", subtitle: nil, symbol: "person.slash")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top) { ConnectionSwitcher() }
    }
}

/// A toggle row: click to add this assignee to the filter, click again to remove it.
private struct AssigneeRow: View {
    @Environment(Store.self) private var store
    let name: String
    let filterKey: String
    let title: String
    let subtitle: String?
    let symbol: String

    var body: some View {
        Button { store.toggleAssignee(filterKey) } label: {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).lineLimit(1)
                        if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                } icon: { Image(systemName: symbol) }
                Spacer()
                Text("\(store.count(assignee: name))").foregroundStyle(.secondary)
                Image(systemName: "checkmark").opacity(store.assigneeFilter.contains(filterKey) ? 1 : 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(subtitle.map { "\(name) <\($0)>" } ?? "Show only issues assigned to \(title). Select several to combine.")
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
    @Environment(Store.self) private var store
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
                    if store.isBlocked(issue) { Image(systemName: "lock.fill").font(.caption).foregroundStyle(.red).help("Blocked by an unfinished dependency") }
                    AssigneeLabel(issue: issue)
                    DueBadge(issue: issue)
                }
                if issue.isEpic { let p = store.progress(of: issue.id); EpicProgress(done: p.done, total: p.total) }
            }
            Spacer(minLength: 0)
            PriorityBadge(priority: issue.priority)
        }
        .padding(.vertical, 2)
        .contextMenu { AssigneeActions(issue: issue) }
    }
}


/// Content with a right-hand panel whose width is stored by us, so it stays the same when the selection changes.
struct SidePanelLayout<Content: View, Panel: View>: View {
    let showPanel: Bool
    @ViewBuilder var content: Content
    @ViewBuilder var panel: Panel
    @AppStorage("detailPanelWidth") private var storedWidth: Double = 420
    @State private var dragStart: Double?

    var body: some View {
        HStack(spacing: 0) {
            content.frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
            if showPanel {
                Divider()
                    .overlay(Color.clear.frame(width: 8).contentShape(Rectangle())
                        .onHover { $0 ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { g in
                                let start = dragStart ?? storedWidth
                                dragStart = start
                                storedWidth = min(720, max(340, start - g.translation.width))
                            }
                            .onEnded { _ in dragStart = nil }))
                panel
                    .frame(width: min(720, max(340, storedWidth)))
                    .frame(maxHeight: .infinity)
                    .background(.background)
            }
        }
    }
}
