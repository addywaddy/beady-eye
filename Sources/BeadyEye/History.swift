import Foundation

// MARK: - What bd returns

/// One commit in an issue's history: the issue's complete state as of that commit.
struct HistoryEntry: Identifiable, Decodable {
    let commitHash: String
    let committer: String?
    let commitDate: String
    let issue: Issue
    var id: String { commitHash }
    var date: Date? { commitDate.beadsDate }

    enum CodingKeys: String, CodingKey {
        case commitHash = "CommitHash", committer = "Committer", commitDate = "CommitDate", issue = "Issue"
    }
}

/// `bd history --events`: who did what. The commits themselves are all authored by "beads".
struct AuditEvent: Decodable {
    let eventType: String
    let actor: String?
    let createdAt: String
    var date: Date? { createdAt.beadsDate }

    enum CodingKeys: String, CodingKey {
        case eventType = "event_type", actor, createdAt = "created_at"
    }
}

// MARK: - Diffing

struct DiffLine: Identifiable {
    enum Kind { case same, added, removed, gap }
    let id: Int
    let kind: Kind
    let text: String
}

struct FieldChange: Identifiable {
    enum Value {
        case short(old: String?, new: String?)
        case text([DiffLine])
    }
    let label: String
    let value: Value
    var id: String { label }
}

struct HistoryRow: Identifiable {
    let entry: HistoryEntry
    let isCreation: Bool
    let changes: [FieldChange]
    let actor: String?
    var id: String { entry.id }

    var title: String {
        if isCreation { return "Created" }
        for c in changes where c.label == "Status" {
            if case .short(let old, let new) = c.value {
                if new == StatusInfo.named("closed").label { return "Closed" }
                if old == StatusInfo.named("closed").label { return "Reopened" }
            }
        }
        return "Changed " + changes.map(\.label).joined(separator: ", ")
    }
}

private func dayString(_ s: String?) -> String? {
    s?.beadsDate.map { $0.formatted(.dateTime.year().month(.abbreviated).day()) } ?? s
}

private func statusLabel(_ raw: String) -> String { StatusInfo.named(raw).label }

/// What changed between two snapshots of the same issue. Short fields become "old → new"; long text
/// fields become a line diff. An unchanged field produces nothing.
func changes(from old: Issue, to new: Issue) -> [FieldChange] {
    var out: [FieldChange] = []

    func short(_ label: String, _ a: String?, _ b: String?) {
        let x = (a?.isEmpty ?? true) ? nil : a
        let y = (b?.isEmpty ?? true) ? nil : b
        if x != y { out.append(FieldChange(label: label, value: .short(old: x, new: y))) }
    }
    func long(_ label: String, _ a: String?, _ b: String?) {
        let x = a ?? "", y = b ?? ""
        if x != y { out.append(FieldChange(label: label, value: .text(lineDiff(x, y)))) }
    }

    short("Title", old.title, new.title)
    short("Status", statusLabel(old.status), statusLabel(new.status))
    short("Priority", "P\(old.priority)", "P\(new.priority)")
    short("Type", old.issueType, new.issueType)
    short("Assignee", old.assignee, new.assignee)
    short("Due", dayString(old.dueAt), dayString(new.dueAt))
    short("Deferred until", dayString(old.deferUntil), dayString(new.deferUntil))
    short("Epic", old.parent, new.parent)
    short("Close reason", old.closeReason, new.closeReason)
    long("Description", old.description, new.description)
    long("Acceptance criteria", old.acceptanceCriteria, new.acceptanceCriteria)
    long("Design", old.design, new.design)
    long("Notes", old.notes, new.notes)
    return out
}

/// Line-based diff (longest common subsequence). Unchanged stretches longer than `2 * context` lines are
/// collapsed to a single gap marker so the change stays in view.
func lineDiff(_ old: String, _ new: String, context: Int = 2) -> [DiffLine] {
    let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
    let b = new.isEmpty ? [] : new.components(separatedBy: "\n")
    let n = a.count, m = b.count

    var lcs = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
    if n > 0, m > 0 {
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
    }

    var ops: [(DiffLine.Kind, String)] = []
    var i = 0, j = 0
    while i < n || j < m {
        if i < n, j < m, a[i] == b[j] { ops.append((.same, a[i])); i += 1; j += 1 }
        else if i < n, j == m || lcs[i + 1][j] >= lcs[i][j + 1] { ops.append((.removed, a[i])); i += 1 }   // removals first
        else { ops.append((.added, b[j])); j += 1 }
    }

    // Keep changed lines plus `context` neighbours; collapse the rest.
    var keep = [Bool](repeating: false, count: ops.count)
    for (k, op) in ops.enumerated() where op.0 != .same {
        for d in -context...context where ops.indices.contains(k + d) { keep[k + d] = true }
    }
    var lines: [DiffLine] = []
    var skipped = false
    for (k, op) in ops.enumerated() {
        if keep[k] {
            if skipped { lines.append(DiffLine(id: lines.count, kind: .gap, text: "")); skipped = false }
            lines.append(DiffLine(id: lines.count, kind: op.0, text: op.1))
        } else {
            skipped = true
        }
    }
    if skipped { lines.append(DiffLine(id: lines.count, kind: .gap, text: "")) }
    return lines
}

// MARK: - Putting history together

/// Newest first. Snapshots that differ in no visible field (for example a commit that only touched
/// labels or comments) are dropped. The actor comes from the nearest audit event within a few seconds.
///
/// `complete` says the entries reach back to the issue's creation. If not, the oldest entry is only a
/// baseline to compare against (it isn't shown, and it isn't the creation).
func historyRows(entries: [HistoryEntry], events: [AuditEvent], complete: Bool = true) -> [HistoryRow] {
    // bd returns newest first; walk oldest to newest so each entry is compared with the one before it.
    let ordered = Array(entries.reversed())
    var rows: [HistoryRow] = []
    for (i, e) in ordered.enumerated() {
        if i == 0, !complete { continue }
        let creation = i == 0
        let diffs = creation ? [] : changes(from: ordered[i - 1].issue, to: e.issue)
        if !creation, diffs.isEmpty { continue }
        let actor = e.date.flatMap { d in
            events.compactMap { ev -> (AuditEvent, TimeInterval)? in
                guard let t = ev.date else { return nil }
                let delta = abs(t.timeIntervalSince(d))
                return delta <= 3 ? (ev, delta) : nil
            }.min { $0.1 < $1.1 }?.0.actor
        }
        rows.append(HistoryRow(entry: e, isCreation: creation, changes: diffs, actor: actor))
    }
    return rows.reversed()
}
