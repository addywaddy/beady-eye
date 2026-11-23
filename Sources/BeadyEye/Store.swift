import Foundation
import Observation
import AppKit

/// What the sidebar is pointing at: a status-style filter, an assignee, or an epic's children.
enum SidebarItem: Hashable {
    case filter(Filter)
    case status(String)   // a status beyond Open / In Progress / Closed, shown when something has it
    case assignee(String)
    case mine
    case unassigned
    case epic(String)
}

enum Filter: String, CaseIterable, Identifiable {
    case all, open, ready, inProgress, blocked, overdue, closed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: "All"
        case .open: "Open"
        case .ready: "Ready"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
        case .overdue: "Overdue"
        case .closed: "Closed"
        }
    }
    /// What each entry means, in beads' terms.
    var help: String {
        switch self {
        case .all: "Every issue"
        case .open: "Status “open”"
        case .ready: "Ready to work on (bd ready)"
        case .inProgress: "Status “in_progress”"
        case .blocked: "Waiting on unfinished dependencies (bd blocked)"
        case .overdue: "Past their due date (bd list --overdue)"
        case .closed: "Status “closed”"
        }
    }
    var symbol: String {
        switch self {
        case .all: "list.bullet"
        case .open: "circle"
        case .ready: "bolt"
        case .inProgress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle"
        case .overdue: "calendar.badge.exclamationmark"
        case .closed: "checkmark.circle"
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
    var blockedBy: [String: [String]] = [:]   // `bd blocked`: issue id -> the unfinished issues it waits on
    var statuses: [StatusInfo] = StatusInfo.builtIn { didSet { StatusInfo.known = statuses } }
    var types: [String] = fallbackIssueTypes
    var sidebar: SidebarItem = .filter(.all)
    var assigneeFilter: Set<String> = []   // sidebar assignee toggles; "" is Unassigned; empty means anyone
    var epicFilter: Set<String> = []   // sidebar epic toggles (epic ids); empty means any parent
    var labelFilter: Set<String> = []   // sidebar label toggles; an issue matches if it has any of them
    var statusFilter: Set<String> = []   // sidebar status toggles; empty means every status
    var me: String?             // the name bd uses for "you"; claims are recorded under it
    var meEmail: String?        // git user.email, which bd stores as an issue's `owner`
    var showNewIssue = false
    var showMemories = false
    var memories: [Memory] = []
    var memoriesError: String?
    var newIssueParent: String?
    /// Whether epics appear as cards on the board (their children always do). On by default.
    var showEpicsOnBoard: Bool = UserDefaults.standard.object(forKey: "showEpicsOnBoard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showEpicsOnBoard, forKey: "showEpicsOnBoard") }
    }
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
        issues = []; readyIDs = []; blockedBy = [:]; detail = nil; selection = nil; error = nil; refreshError = nil
        sidebar = .filter(.all)
        statusFilter = []
        labelFilter = []
        epicFilter = []
        assigneeFilter = []
        me = nil; meEmail = nil
        guard let ws = workspace else { client = nil; return }
        let c = BdClient(workspace: ws)
        client = c
        Task { [weak self] in
            let who = await c.currentIdentity()
            if let self, self.client === c { self.me = who.name; self.meEmail = who.email }
        }
        // Statuses and types are the project's own (bd may have custom ones), so ask bd.
        Task { [weak self] in
            let st = try? await c.statuses(), ty = try? await c.issueTypes()
            guard let self, self.client === c else { return }
            if let st, !st.isEmpty { self.statuses = st }
            if let ty, !ty.isEmpty { self.types = ty }
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
        case .open: issues.filter { $0.status == "open" }   // exactly the board's Open column
        case .ready: issues.filter { readyIDs.contains($0.id) }
        case .inProgress: issues.filter { $0.status == "in_progress" }
        case .blocked: issues.filter(isBlocked)   // `bd blocked`: waiting on dependencies, any status
        case .overdue: issues.filter(\.isOverdue)
        case .closed: issues.filter(\.isClosed)
        case .all: issues
        }
    }

    func matchesSearch(_ i: Issue) -> Bool {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty || i.title.lowercased().contains(q) || i.id.lowercased().contains(q) || (i.description ?? "").lowercased().contains(q)
    }

    /// Open work by priority first; finished work sinks to the bottom of mixed lists such as "All".
    private func byPriority(_ a: Issue, _ b: Issue) -> Bool {
        (a.isClosed ? 1 : 0, a.priority, a.createdAt ?? "") < (b.isClosed ? 1 : 0, b.priority, b.createdAt ?? "")
    }

    func issues(for item: SidebarItem) -> [Issue] {
        switch item {
        case .filter(let f): issues(for: f)
        case .status(let name): issues.filter { $0.status == name }
        case .assignee(let a): issues.filter { $0.assignee == a && !$0.isClosed }
        case .mine: issues.filter { isMine($0) && !$0.isClosed }
        case .unassigned: issues.filter { ($0.assignee ?? "").isEmpty && !$0.isClosed }
        case .epic(let id): issues.filter { $0.parent == id }
        }
    }

    var visible: [Issue] { issues(for: sidebar).filter(matchesStatusFilter).filter(matchesSearch).sorted(by: byPriority) }

    func matchesStatusFilter(_ i: Issue) -> Bool {
        (statusFilter.isEmpty || statusFilter.contains(i.status))
            && (assigneeFilter.isEmpty || assigneeFilter.contains(i.assignee ?? ""))
            && (epicFilter.isEmpty || epicFilter.contains(i.parent ?? ""))
            && (labelFilter.isEmpty || !labelFilter.isDisjoint(with: i.labels ?? []))
    }

    var labels: [String] { Set(issues.flatMap { $0.labels ?? [] }).sorted() }
    func count(label: String) -> Int { issues.filter { ($0.labels ?? []).contains(label) }.count }
    func toggleLabel(_ l: String) {
        if labelFilter.contains(l) { labelFilter.remove(l) } else { labelFilter.insert(l) }
    }

    func toggleEpic(_ id: String) {
        if epicFilter.contains(id) { epicFilter.remove(id) } else { epicFilter.insert(id) }
    }

    func toggleAssignee(_ name: String) {
        if assigneeFilter.contains(name) { assigneeFilter.remove(name) } else { assigneeFilter.insert(name) }
    }

    func count(assignee name: String) -> Int { issues.filter { ($0.assignee ?? "") == name }.count }

    /// What the board and graph show: the same selection as the list, so "Open" fills only the Open
    /// column and "All" (the default) fills every column.
    var scoped: [Issue] { issues(for: sidebar) }

    /// bd's status categories, in board order. These are the board's columns.
    static let categories = ["active", "wip", "done", "frozen"]

    func category(of status: String) -> String { statuses.first { $0.name == status }?.category ?? StatusInfo.named(status).category }

    /// Issues in one board column (a bd category), honouring the sidebar scope, status toggles and search box.
    func column(category cat: String) -> [Issue] {
        scoped.filter { category(of: $0.status) == cat && (showEpicsOnBoard || !$0.isEpic) && matchesStatusFilter($0) && matchesSearch($0) }.sorted(by: byPriority)
    }

    func toggleStatus(_ name: String) {
        if statusFilter.contains(name) { statusFilter.remove(name) } else { statusFilter.insert(name) }
    }

    /// Dropping a card on a category column: pick the status to use. A single toggled status in that category wins,
    /// otherwise bd's own default for the category.
    func status(forDropIn cat: String) -> String? {
        let inCat = statuses.filter { $0.category == cat }.map(\.name)
        if let picked = inCat.first(where: statusFilter.contains) { return picked }
        let preferred = ["active": "open", "wip": "in_progress", "done": "closed", "frozen": "deferred"][cat]
        if let p = preferred, inCat.contains(p) { return p }
        return inCat.first
    }

    func move(_ id: String, toCategory cat: String) {
        guard let issue = issue(id), category(of: issue.status) != cat, let status = status(forDropIn: cat) else { return }
        move(id, to: status)
    }

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

    /// Waiting on an unfinished dependency, per `bd blocked`. This is separate from the `blocked` *status*:
    /// an issue can be in progress and still blocked.
    func isBlocked(_ i: Issue) -> Bool { !(blockedBy[i.id] ?? []).isEmpty }

    /// The statuses every board shows, whether or not anything is in them.
    private static let coreStatuses: Set<String> = ["open", "in_progress", "closed"]

    /// Board columns, in bd's status order: the core workflow always, any other status only when an issue
    /// has it (so pinned, hooked, deferred and custom statuses show up without cluttering an empty board).
    var columnStatuses: [StatusInfo] {
        let present = Set(issues.map(\.status))
        var cols = statuses
        // A status bd no longer lists (a removed custom status) must still not hide its issues.
        for name in present.subtracting(cols.map(\.name)).sorted() { cols.append(StatusInfo.named(name)) }
        return cols
    }

    /// Statuses that get their own sidebar row: those beyond the three core ones that have issues.
    var extraStatuses: [StatusInfo] {
        let present = Set(issues.map(\.status))
        return columnStatuses.filter { !Self.coreStatuses.contains($0.name) && present.contains($0.name) }
    }

    func loadMemories() async {
        guard let client else { return }
        do { let m = try await client.memories(); if self.client === client { memories = m; memoriesError = nil } }
        catch { memoriesError = error.localizedDescription }
    }

    func remember(_ text: String, key: String? = nil) {
        guard let client else { return }
        Task {
            do { try await client.remember(text, key: key) } catch { memoriesError = error.localizedDescription }
            await loadMemories()
        }
    }

    func forget(_ key: String) {
        guard let client else { return }
        memories.removeAll { $0.key == key }
        Task {
            do { try await client.forget(key) } catch { memoriesError = error.localizedDescription }
            await loadMemories()
        }
    }

    func presentNewIssue(parent: String? = nil) { newIssueParent = parent; showNewIssue = true }

    func count(_ f: Filter) -> Int { issues(for: f).count }

    // MARK: Loading

    func refresh() async {
        guard let client else { return }
        do {
            async let all = client.listAll()
            async let ready = client.readyIDs()
            async let blocked = client.blocked()
            let (a, r, b) = try await (all, ready, blocked)
            guard self.client === client else { return }   // connection changed while we were waiting
            if a != issues { issues = a }
            readyIDs = r
            if b != blockedBy { blockedBy = b }
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
                // Make sure the new issue is visible: switch to All if the current view would hide it.
                if !issues(for: sidebar).contains(where: { $0.id == id }) { sidebar = .filter(.all) }
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
    /// Defers an issue, optionally until a day (bd then wakes it on its own). Moves the card at once.
    func defer_(_ id: String, until date: Date?) {
        applyLocally(id) { $0.status = "deferred" }
        let v = date.map { Self.dayFormatter.string(from: $0) }
        perform { try await $0.deferIssue(id, until: v) }
    }
    func undefer(_ id: String) {
        applyLocally(id) { $0.status = "open" }
        perform { try await $0.undefer(id) }
    }
    func setParent(_ id: String, _ parent: String?) { perform { try await $0.update(id, ["--parent", parent ?? ""]) } }
    func close(_ id: String, reason: String?) { perform { try await $0.close(id, reason: reason) } }
    func reopen(_ id: String) { perform { try await $0.reopen(id) } }
    /// Deletes for good. The card disappears at once and the selection is cleared.
    func delete(_ id: String) {
        issues.removeAll { $0.id == id }
        if selection == id { selection = nil; detail = nil }
        perform { try await $0.delete(id) }
    }

    func comment(_ id: String, _ text: String) { perform { try await $0.comment(id, text: text) } }
    func addLabel(_ id: String, _ l: String) { perform { try await $0.addLabel(id, l) } }
    func removeLabel(_ id: String, _ l: String) { perform { try await $0.removeLabel(id, l) } }
    func addDependency(_ id: String, on other: String) { perform { try await $0.addDependency(id, dependsOn: other) } }
}
