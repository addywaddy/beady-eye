import Foundation
import Observation
import AppKit

enum Filter: String, CaseIterable, Identifiable {
    case active, ready, inProgress, blocked, closed, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .active: "Open"
        case .ready: "Ready"
        case .inProgress: "In Progress"
        case .blocked: "Blocked"
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
        case .closed: "checkmark.circle"
        case .all: "list.bullet"
        }
    }
}

@MainActor @Observable
final class Store {
    var workspace: URL? { didSet { workspaceChanged() } }
    var issues: [Issue] = []
    var readyIDs: Set<String> = []
    var filter: Filter = .active
    var search = ""
    var selection: String? { didSet { if selection != oldValue { loadDetail() } } }
    var detail: Issue?
    var error: String?
    var isLoading = false
    var recents: [URL] = []

    private var client: BdClient?
    private var poller: Task<Void, Never>?

    init() {
        recents = (UserDefaults.standard.stringArray(forKey: "recents") ?? []).map { URL(fileURLWithPath: $0) }
        if let last = recents.first, FileManager.default.fileExists(atPath: last.path) { workspace = last }
    }

    // MARK: Workspace

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Open"
        panel.message = "Choose a project folder containing a .beads directory"
        if panel.runModal() == .OK { workspace = panel.url }
    }

    private func workspaceChanged() {
        poller?.cancel()
        issues = []; detail = nil; selection = nil; error = nil
        guard let ws = workspace else { client = nil; return }
        client = BdClient(workspace: ws)
        var r = recents.filter { $0 != ws }
        r.insert(ws, at: 0)
        recents = Array(r.prefix(8))
        UserDefaults.standard.set(recents.map(\.path), forKey: "recents")
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
        case .closed: issues.filter(\.isClosed)
        case .all: issues
        }
    }

    var visible: [Issue] {
        let base = issues(for: filter)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = q.isEmpty ? base : base.filter {
            $0.title.lowercased().contains(q) || $0.id.lowercased().contains(q) || ($0.description ?? "").lowercased().contains(q)
        }
        return filtered.sorted { ($0.priority, $0.createdAt ?? "") < ($1.priority, $1.createdAt ?? "") }
    }

    func count(_ f: Filter) -> Int { issues(for: f).count }

    // MARK: Loading

    func refresh() async {
        guard let client else { return }
        do {
            async let all = client.listAll()
            async let ready = client.readyIDs()
            let (a, r) = try await (all, ready)
            if a != issues { issues = a }
            readyIDs = r
            error = nil
            if selection != nil { await reloadDetail() }
        } catch { self.error = error.localizedDescription }
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
            catch { self.error = error.localizedDescription }
        }
    }

    func create(title: String, type: String, priority: Int, description: String) {
        guard let client else { return }
        Task {
            do {
                let id = try await client.create(title: title, type: type, priority: priority, description: description)
                await refresh()
                filter = .active
                selection = id
            } catch { self.error = error.localizedDescription }
        }
    }

    func setStatus(_ id: String, _ s: String) { perform { try await $0.setStatus(id, s) } }
    func setPriority(_ id: String, _ p: Int) { perform { try await $0.update(id, ["-p", String(p)]) } }
    func setTitle(_ id: String, _ t: String) { perform { try await $0.update(id, ["--title", t]) } }
    func setDescription(_ id: String, _ d: String) { perform { try await $0.update(id, ["-d", d, "--allow-empty-description"]) } }
    func close(_ id: String, reason: String?) { perform { try await $0.close(id, reason: reason) } }
    func reopen(_ id: String) { perform { try await $0.reopen(id) } }
    func comment(_ id: String, _ text: String) { perform { try await $0.comment(id, text: text) } }
    func addLabel(_ id: String, _ l: String) { perform { try await $0.addLabel(id, l) } }
    func removeLabel(_ id: String, _ l: String) { perform { try await $0.removeLabel(id, l) } }
    func addDependency(_ id: String, on other: String) { perform { try await $0.addDependency(id, dependsOn: other) } }
}
