import Foundation

struct Issue: Identifiable, Hashable, Decodable {
    let id: String
    var title: String
    var description: String?
    var status: String
    var priority: Int
    var issueType: String
    var assignee: String?
    var owner: String?
    var createdAt: String?
    var updatedAt: String?
    var labels: [String]?
    var notes: String?
    var design: String?
    var acceptanceCriteria: String?
    var dependencyCount: Int?
    var dependentCount: Int?
    var commentCount: Int?
    var dependencies: [Related]?
    var dependents: [Related]?
    var comments: [Comment]?
    var parent: String?
    var closedAt: String?
    var closeReason: String?
    var dueAt: String?
    var deferUntil: String?

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, assignee, owner, labels, notes, design, parent
        case dueAt = "due_at"
        case closedAt = "closed_at"
        case closeReason = "close_reason"
        case deferUntil = "defer_until"
        case dependencies, dependents, comments
        case issueType = "issue_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case acceptanceCriteria = "acceptance_criteria"
        case dependencyCount = "dependency_count"
        case dependentCount = "dependent_count"
        case commentCount = "comment_count"
    }

    /// Compares everything the list, board and graph display, so a refresh redraws when any of it changes.
    static func == (a: Issue, b: Issue) -> Bool {
        a.id == b.id && a.updatedAt == b.updatedAt && a.status == b.status && a.title == b.title
            && a.priority == b.priority && a.assignee == b.assignee && a.dueAt == b.dueAt && a.parent == b.parent
            && a.labels == b.labels && a.deferUntil == b.deferUntil && a.description == b.description && a.closeReason == b.closeReason
            && a.comments == b.comments && a.notes == b.notes && a.dependencies == b.dependencies && a.dependents == b.dependents
    }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isClosed: Bool { status == "closed" }
    var isEpic: Bool { issueType == "epic" }

    var dueDate: Date? { dueAt?.beadsDate }
    var deferDate: Date? { deferUntil?.beadsDate }

    /// Same as `bd list --overdue`: the due time has passed and the issue isn't closed. (A date-only due
    /// date is local midnight, so something due today counts as overdue once today has begun.)
    var isOverdue: Bool {
        guard !isClosed, let d = dueDate else { return false }
        return d < Date()
    }
    var isDueSoon: Bool {
        guard !isClosed, !isOverdue, let d = dueDate else { return false }
        let cal = Calendar.current
        return cal.startOfDay(for: d) <= cal.date(byAdding: .day, value: 2, to: cal.startOfDay(for: .now))!
    }
}

/// A dependency/dependent. `bd show` returns full issue objects; `bd list` returns bare edge
/// records (`depends_on_id`, `type`), so every field except the id is tolerant of absence.
struct Related: Identifiable, Hashable, Decodable {
    let id: String
    var title: String
    var status: String
    var priority: Int?
    var issueType: String?
    var dependencyType: String?

    enum CodingKeys: String, CodingKey {
        case id, title, status, priority, type
        case dependsOnId = "depends_on_id"
        case issueType = "issue_type"
        case dependencyType = "dependency_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? c.decode(String.self, forKey: .dependsOnId)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "open"
        priority = try c.decodeIfPresent(Int.self, forKey: .priority)
        issueType = try c.decodeIfPresent(String.self, forKey: .issueType)
        dependencyType = try c.decodeIfPresent(String.self, forKey: .dependencyType)
            ?? c.decodeIfPresent(String.self, forKey: .type)
    }
}

struct Comment: Identifiable, Hashable, Decodable {
    let id: String
    var author: String?
    var text: String
    var createdAt: String?

    enum CodingKeys: String, CodingKey {
        case id, author, text
        case createdAt = "created_at"
    }
}

/// A status as `bd statuses` defines it (built in or custom). Category is one of active, wip, done, frozen.
struct StatusInfo: Identifiable, Hashable {
    let name: String
    let category: String
    var id: String { name }

    /// bd shows the raw name; this just makes "in_progress" readable.
    var label: String { name.split(separator: "_").map { $0.capitalized }.joined(separator: " ") }

    var symbol: String {
        switch name {
        case "open": "circle"
        case "in_progress": "circle.lefthalf.filled"
        case "blocked": "exclamationmark.circle"
        case "deferred": "clock"
        case "closed": "checkmark.circle.fill"
        case "pinned": "pin"
        case "hooked": "link"
        default:
            switch category {
            case "wip": "circle.lefthalf.filled"
            case "done": "checkmark.circle.fill"
            case "frozen": "snowflake"
            default: "circle"
            }
        }
    }

    /// Used only until (or if) `bd statuses` can't be read.
    static let builtIn: [StatusInfo] = [
        StatusInfo(name: "open", category: "active"), StatusInfo(name: "in_progress", category: "wip"),
        StatusInfo(name: "blocked", category: "wip"), StatusInfo(name: "deferred", category: "frozen"),
        StatusInfo(name: "closed", category: "done"), StatusInfo(name: "pinned", category: "frozen"),
        StatusInfo(name: "hooked", category: "wip"),
    ]

    /// The statuses of the open project, so views that only have a status name (an icon, a history line)
    /// can look up its category. Set by the store from `bd statuses`.
    static var known: [StatusInfo] = builtIn

    static func named(_ name: String) -> StatusInfo {
        known.first { $0.name == name } ?? StatusInfo(name: name, category: "active")
    }
}

/// Only used until (or if) `bd types` can't be read.
let fallbackIssueTypes = ["task", "bug", "feature", "chore", "epic", "decision", "spike", "story", "milestone"]

extension String {
    /// "2026-11-23T13:15:53.61012Z" -> Date, tolerant of fractional seconds.
    var beadsDate: Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: self) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: self)
    }
}

/// One `bd remember` note.
struct Memory: Identifiable, Hashable {
    let key: String
    let text: String
    var id: String { key }
}
