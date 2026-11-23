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

    enum CodingKeys: String, CodingKey {
        case id, title, description, status, priority, assignee, owner, labels, notes, design
        case dependencies, dependents, comments
        case issueType = "issue_type"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case acceptanceCriteria = "acceptance_criteria"
        case dependencyCount = "dependency_count"
        case dependentCount = "dependent_count"
        case commentCount = "comment_count"
    }

    /// Only identity matters for list selection; detail is refetched.
    static func == (a: Issue, b: Issue) -> Bool { a.id == b.id && a.updatedAt == b.updatedAt && a.status == b.status }
    func hash(into h: inout Hasher) { h.combine(id) }

    var isClosed: Bool { status == "closed" }
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

enum Status: String, CaseIterable, Identifiable {
    case open, in_progress, blocked, deferred, closed
    var id: String { rawValue }
    var label: String {
        switch self {
        case .in_progress: "In Progress"
        default: rawValue.capitalized
        }
    }
    var symbol: String {
        switch self {
        case .open: "circle"
        case .in_progress: "circle.lefthalf.filled"
        case .blocked: "exclamationmark.circle"
        case .deferred: "clock"
        case .closed: "checkmark.circle.fill"
        }
    }
}

let issueTypes = ["task", "bug", "feature", "epic", "chore", "decision"]

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
