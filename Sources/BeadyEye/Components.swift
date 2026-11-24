import SwiftUI

extension Int {
    var priorityColor: Color {
        switch self {
        case 0: .red
        case 1: .orange
        case 2: .yellow
        case 3: .blue
        default: .gray
        }
    }
}

struct PriorityBadge: View {
    let priority: Int
    var body: some View {
        Text("P\(priority)")
            .font(.caption.monospacedDigit().weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(priority.priorityColor.opacity(0.18), in: Capsule())
            .foregroundStyle(priority.priorityColor)
    }
}

struct TypeBadge: View {
    let type: String
    var symbol: String {
        switch type {
        case "bug": "ladybug"
        case "feature": "sparkles"
        case "epic": "square.stack.3d.up"
        case "chore": "wrench"
        case "decision": "scale.3d"
        case "spike": "bolt.horizontal"
        case "story": "book"
        case "milestone": "flag"
        default: "checklist"
        }
    }
    var body: some View { Label(type, systemImage: symbol).font(.caption).foregroundStyle(.secondary) }
}

struct StatusIcon: View {
    let status: String
    var body: some View {
        let info = StatusInfo.named(status)
        let color: Color = switch (status, info.category) {
        case ("blocked", _): .red
        case (_, "done"): .green
        case (_, "wip"): .blue
        case (_, "frozen"): .gray
        default: .secondary
        }
        Image(systemName: info.symbol).foregroundStyle(color)
    }
}

struct DueBadge: View {
    let issue: Issue
    var body: some View {
        if let d = issue.dueDate {
            let cal = Calendar.current
            let day = d.formatted(.dateTime.month(.abbreviated).day())
            let text = issue.isOverdue ? "Overdue · \(day)" : cal.isDateInToday(d) ? "Due today" : cal.isDateInTomorrow(d) ? "Due tomorrow" : "Due \(day)"
            let color: Color = issue.isOverdue ? .red : issue.isDueSoon ? .orange : .secondary
            Label(text, systemImage: "calendar")
                .font(.caption).foregroundStyle(color)
                .opacity(issue.isClosed ? 0.5 : 1)
        }
    }
}

/// "Back Dec 3" on an issue that is deferred until a date.
struct DeferBadge: View {
    let issue: Issue
    var body: some View {
        if issue.status == "deferred", let d = issue.deferDate {
            Label("Back \(d.formatted(.dateTime.month(.abbreviated).day()))", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct EpicProgress: View {
    let done: Int
    let total: Int
    var body: some View {
        if total > 0 {
            HStack(spacing: 6) {
                ProgressView(value: Double(done), total: Double(total)).progressViewStyle(.linear).frame(maxWidth: 90)
                Text("\(done)/\(total)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
}

/// The assignee, highlighted when it's you.
struct AssigneeLabel: View {
    @Environment(Store.self) private var store
    let issue: Issue
    var body: some View {
        if let a = issue.assignee, !a.isEmpty {
            let mine = store.isMine(issue)
            Label(mine ? "\(a) (you)" : a, systemImage: mine ? "person.fill" : "person")
                .font(.caption).foregroundStyle(mine ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        }
    }
}

/// Right-click actions shared by list rows and board cards.
struct AssigneeActions: View {
    @Environment(Store.self) private var store
    let issue: Issue
    var body: some View {
        let unassigned = (issue.assignee ?? "").isEmpty
        if !issue.isClosed {
            // Claiming (assign + start, atomically) only works on an open issue; on any other status it would
            // be the same as assigning, so there is just one item.
            if unassigned && issue.status == "open" {
                Button("Claim and Start", systemImage: "hand.raised") { store.claim(issue.id) }
            }
            if let me = store.me, issue.assignee != me {
                Button("Assign to Me", systemImage: "person.crop.circle") { store.setAssignee(issue.id, me) }
            }
            if !unassigned { Button("Unassign", systemImage: "person.slash") { store.setAssignee(issue.id, "") } }
        }
    }
}

/// "Priority ▸ P0–P4" for context menus. Priorities are bd's five fixed levels, not a rank.
struct PriorityActions: View {
    @Environment(Store.self) private var store
    let issue: Issue
    private static let names = ["Critical", "High", "Medium", "Low", "Backlog"]
    var body: some View {
        Menu("Priority", systemImage: "flag") {
            ForEach(0...4, id: \.self) { p in
                Button { store.setPriority(issue.id, p) } label: {
                    if issue.priority == p { Label("P\(p) · \(Self.names[p])", systemImage: "checkmark") }
                    else { Text("P\(p) · \(Self.names[p])") }
                }
            }
        }
    }
}

/// Left-to-right layout that wraps onto new lines, for label chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            maxX = max(maxX, x - spacing)
        }
        return CGSize(width: maxX, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The issue's exact bd status, shown on board cards because columns are categories.
struct StatusChip: View {
    let status: String
    var body: some View {
        let info = StatusInfo.named(status)
        Label(info.label, systemImage: info.symbol)
            .font(.caption).labelStyle(.titleAndIcon).foregroundStyle(.secondary)
            .help("Status: \(status) (\(info.category))")
    }
}
