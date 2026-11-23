import Foundation
import Observation
import AppKit

/// What the sidebar is pointing at: a status-style filter, an assignee, or an epic's children.
enum SidebarItem: Hashable {
    case filter(Filter)
    case assignee(String)
    case mine
    case unassigned
    case epic(String)
}

enum Filter: String, CaseIterable, Identifiable {
    case active, ready, inProgress, blocked, overdue, closed, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .active: "Active"
        case .ready: "Ready"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
        case .overdue: "Overdue"
        case .closed: "Closed"
        case .all: "All"
        }
    }
    var symbol: String {
        switch self {
        case .active: "tray"
        case .ready: "bolt"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle"
        case .overdue: "calendar.badge.exclamationmark"
        case .closed: "checkmark.circle"
        case .all: "list.bullet"
        }
    }
}

/// A saved bd project: a folder containing `.beads`. Where its data actually lives (local or a
/// remote Dolt server) is bd's business, configured in that folder's `.beads/metadata.json`.
struct Connection: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var url: URL { URL(fileURLWithPath: path) }
}

enum ViewMode: String, CaseIterable, Identifiable {
    case list, board, graph
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .list: "list.bullet"
        case .board: "rectangle.split.3x1"
        case .graph: "point.3.connected.trianglepath.dotted"
        }
    }
}

@MainActor @Observable
final class Store {
    var connections: [Connection] = [] { didSet { saveConnections() } }
    var activeID: Connection.ID? {
        didSet {
            guard activeID != oldValue else { return }
            UserDefaults.standard.set(activeID?.uuidString, forKey: "activeConnection")
            activeChanged()
        }
    }
    var issues: [Issue] = []
    var readyIDs: Set<String> = []
    var sidebar: SidebarItem = .filter(.active)
    var me: String?             // the name bd uses for "you"; claims are recorded under it
    var meEmail: String?        // git user.email, which bd stores as an issue's `owner`
    var showNewIssue = false
    var newIssueParent: String?
    var viewMode: ViewMode = ViewMode(rawValue: UserDefaults.standard.string(forKey: "viewMode") ?? "") ?? .list {
        didSet { UserDefaults.standard.set(viewMode.rawValue, forKey: "viewMode") }
    }
    var search = ""
    var selection: String? { didSet { if selection != oldValue { loadDetail() } } }
    var detail: Issue?
    var error: String?          // result of something the user did: shown as an alert
    var refreshError: String?   // background refresh failing: shown as a banner, never an alert loop

    private var client: BdClient?
    private var poller: Task<Void, Never>?

    var active: Connection? { connections.first { $0.id == activeID } }
    var workspace: URL? { active?.url }

    init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "connections"), let saved = try? JSONDecoder().decode([Connection].self, from: data) {
            connections = saved
        } else {
            // First run with connections: adopt the old "recents" list.
            connections = (d.stringArray(forKey: "recents") ?? [])
                .filter { FileManager.default.fileExists(atPath: $0 + "/.beads") }
                .map { Connection(name: URL(fileURLWithPath: $0).lastPathComponent, path: $0) }
        }
        let saved = d.string(forKey: "activeConnection").flatMap(UUID.init)
        activeID = connections.first { $0.id == saved }?.id ?? connections.first?.id
        activeChanged()   // property observers don't fire for assignments inside init
    }

    // MARK: Connections

    private func saveConnections() {
        if let data = try? JSONEncoder().encode(connections) { UserDefaults.standard.set(data, forKey: "connections") }
    }

    func addConnectionWithPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        panel.message = "Choose a project folder containing a .beads directory"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addConnection(url)
    }

    func addConnection(_ url: URL) {
        let path = url.standardizedFileURL.path
        if let existing = connections.first(where: { $0.path == path }) { activeID = existing.id; return }
        guard FileManager.default.fileExists(atPath: path + "/.beads") else {
            error = "\(url.lastPathComponent) has no .beads directory. Run `bd init` there first, then add it again."
            return
        }
        let c = Connection(name: url.lastPathComponent, path: path)
        connections.append(c)
        activeID = c.id
    }

    func rename(_ id: Connection.ID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let i = connections.firstIndex(where: { $0.id == id }) else { return }
        connections[i].name = n
    }

    func remove(_ id: Connection.ID) {
        let wasActive = id == activeID
        connections.removeAll { $0.id == id }
        if wasActive { activeID = connections.first?.id }
    }

    private func activeChanged() {
        poller?.cancel()
        issues = []; readyIDs = []; detail = nil; selection = nil; error = nil; refreshError = nil
        sidebar = .filter(.active)
        me = nil; meEmail = nil
        guard let ws = workspace else { client = nil; return }
        let c = BdClient(workspace: ws)
        client = c
        Task { [weak self] in
            let who = await c.currentIdentity()
            if let self, self.client === c { self.me = who.name; self.meEmail = who.email }
        }
        poller = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(4))   // pick up changes made via the CLI / agents
            }
        }
    }

    // MARK: Derived

    func issues(for f: Filter) -> [Issue] {
        switch f {
        case .active: issues.filter { !$0.isClosed }
        case .ready: issues.filter { readyIDs.contains($0.id) }
        case .inProgress: issues.filter { $0.status == "in_progress" }
        case .blocked: issues.filter { $0.status == "blocked" || ($0.status == "open" && !readyIDs.contains($0.id)) }
        case .overdue: issues.filter(\.isOverdue)
        case .closed: issues.filter(\.isClosed)
        case .all: issues
        }
    }

    func matchesSearch(_ i: Issue) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || i.title.lowercased().contains(q) || i.id.lowercased().contains(q) || (i.description ?? "").lowercased().contains(q)
    }

    private func byPriority(_ a: Issue, _ b: Issue) -> Bool { (a.priority, a.createdAt ?? "") < (b.priority, b.createdAt ?? "") }

    func issues(for item: SidebarItem) -> [Issue] {
        switch item {
        case .filter(let f): issues(for: f)
        case .assignee(let a): issues.filter { $0.assignee == a && !$0.isClosed }
        case .mine: issues.filter { isMine($0) && !$0.isClosed }
        case .unassigned: issues.filter { ($0.assignee ?? "").isEmpty && !$0.isClosed }
        case .epic(let id): issues.filter { $0.parent == id }
        }
    }

    var visible: [Issue] { issues(for: sidebar).filter(matchesSearch).sorted(by: byPriority) }

    /// What the board and graph show: the sidebar selection applies to them too. "Active" is the
    /// default, so on a board it means the whole board (closed work stays visible in its column).
    var scoped: [Issue] {
        if case .filter(.active) = sidebar { return issues }
        return issues(for: sidebar)
    }

    /// Issues in one board column, honouring the sidebar scope and the search box.
    func column(_ status: String) -> [Issue] { scoped.filter { $0.status == status && matchesSearch($0) }.sorted(by: byPriority) }

    // MARK: Epics and people

    var epics: [Issue] { issues.filter { $0.isEpic && !$0.isClosed }.sorted(by: byPriority) }
    func children(of id: String) -> [Issue] { issues.filter { $0.parent == id }.sorted(by: byPriority) }
    func progress(of id: String) -> (done: Int, total: Int) {
        let kids = issues.filter { $0.parent == id }
        return (kids.filter(\.isClosed).count, kids.count)
    }
    func issue(_ id: String) -> Issue? { issues.first { $0.id == id } }
    var assignees: [String] { Set(issues.compactMap(\.assignee).filter { !$0.isEmpty }).sorted() }

    func isMine(_ i: Issue) -> Bool { me != nil && i.assignee == me }
    /// Everyone with an issue except you, who gets a pinned row of your own.
    var otherAssignees: [String] { assignees.filter { $0 != me } }

    /// An issue's change history, newest first. Events only add "who", so their failure isn't fatal.
    func history(for id: String, limit: Int) async throws -> (entries: [HistoryEntry], events: [AuditEvent]) {
        guard let client else { throw BdError(message: "No project is open.") }
        let entries = try await client.history(id, limit: limit)
        let events = (try? await client.events(id)) ?? []
        return (entries, events)
    }

    func presentNewIssue(parent: String? = nil) { newIssueParent = parent; showNewIssue = true }

    func count(_ f: Filter) -> Int { issues(for: f).count }

    // MARK: Loading

    func refresh() async {
        guard let client else { return }
        do {
            async let all = client.listAll()
            async let ready = client.readyIDs()
            let (a, r) = try await (all, ready)
            guard self.client === client else { return }   // connection changed while we were waiting
            if a != issues { issues = a }
            readyIDs = r
            refreshError = nil
            if selection != nil { await reloadDetail() }
        } catch {
            if self.client === client { refreshError = error.localizedDescription }
        }
    }

    private func loadDetail() {
        detail = nil
        Task { await reloadDetail() }
    }

    private func reloadDetail() async {
        guard let client, let id = selection else { return }
        if let d = try? await client.show(id), selection == id { detail = d }
    }

    // MARK: Actions

    private func perform(_ work: @escaping (BdClient) async throws -> Void) {
        guard let client else { return }
        Task {
            do { try await work(client); await refresh() }
            catch { self.error = error.localizedDescription; await refresh() }
        }
    }

    /// bd reads a bare date as local midnight, so send the local calendar day.
    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func create(title: String, type: String, priority: Int, description: String,
                assignee: String = "", due: Date? = nil, parent: String? = nil) {
        guard let client else { return }
        let dueString = due.map { Self.dayFormatter.string(from: $0) }
        Task {
            do {
                let id = try await client.create(title: title, type: type, priority: priority, description: description,
                                                 assignee: assignee, due: dueString, parent: parent)
                await refresh()
                sidebar = .filter(.active)
                selection = id
            } catch { self.error = error.localizedDescription }
        }
    }

    /// Board drag-and-drop: update the card immediately, then let bd (and the next refresh) confirm.
    func move(_ id: String, to status: String) {
        guard let idx = issues.firstIndex(where: { $0.id == id }), issues[idx].status != status else { return }
        let wasClosed = issues[idx].isClosed
        issues[idx].status = status
        perform { c in
            if status == "closed" { try await c.close(id, reason: nil); return }
            if wasClosed { try await c.reopen(id) }
            if !(wasClosed && status == "open") { try await c.setStatus(id, status) }
        }
    }

    func setStatus(_ id: String, _ s: String) { perform { try await $0.setStatus(id, s) } }
    func setPriority(_ id: String, _ p: Int) { perform { try await $0.update(id, ["-p", String(p)]) } }
    func setTitle(_ id: String, _ t: String) {
        applyLocally(id) { $0.title = t }
        perform { try await $0.update(id, ["--title", t]) }
    }
    func setDescription(_ id: String, _ d: String) {
        applyLocally(id) { $0.description = d }
        perform { try await $0.update(id, ["-d", d, "--allow-empty-description"]) }
    }
    /// Show a change immediately; the refresh that follows the bd call confirms or corrects it.
    func applyLocally(_ id: String, _ change: (inout Issue) -> Void) {
        if let i = issues.firstIndex(where: { $0.id == id }) { change(&issues[i]) }
        if var d = detail, d.id == id { change(&d); detail = d }
    }

    /// For an open issue, `bd update --claim` assigns you and starts it atomically (and fails if someone
    /// else holds it). bd refuses `--claim` on anything not open, so there we just assign you.
    func claim(_ id: String) {
        guard let issue = issue(id) else { return }
        if issue.status == "open" || me == nil {
            perform { try await $0.update(id, ["--claim"]) }
        } else if let me {
            setAssignee(id, me)
        }
    }

    func setAssignee(_ id: String, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        applyLocally(id) { $0.assignee = n.isEmpty ? nil : n }
        perform { try await $0.update(id, ["-a", n]) }
    }
    func setDue(_ id: String, _ date: Date?) {
        let v = date.map { Self.dayFormatter.string(from: $0) } ?? ""
        perform { try await $0.update(id, ["--due", v]) }
    }
    func setParent(_ id: String, _ parent: String?) { perform { try await $0.update(id, ["--parent", parent ?? ""]) } }
    func close(_ id: String, reason: String?) { perform { try await $0.close(id, reason: reason) } }
    func reopen(_ id: String) { perform { try await $0.reopen(id) } }
    func comment(_ id: String, _ text: String) { perform { try await $0.comment(id, text: text) } }
    func addLabel(_ id: String, _ l: String) { perform { try await $0.addLabel(id, l) } }
    func removeLabel(_ id: String, _ l: String) { perform { try await $0.removeLabel(id, l) } }
    func addDependency(_ id: String, on other: String) { perform { try await $0.addDependency(id, dependsOn: other) } }
}
