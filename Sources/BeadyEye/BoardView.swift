import SwiftUI

struct BoardView: View {
    @Environment(Store.self) private var store


    var body: some View {
        GeometryReader { geo in
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    ForEach(Store.categories, id: \.self) { BoardColumn(category: $0) }
                }
                .padding(16)
                .frame(minWidth: geo.size.width)   // columns share the full width, and scroll only when too narrow
            }
        }
        .background(.background.secondary)
        .safeAreaInset(edge: .top, spacing: 0) { RefreshBanner() }
    }
}

struct BoardColumn: View {
    @Environment(Store.self) private var store
    let category: String
    @State private var targeted = false

    var body: some View {
        let items = store.column(category: category)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: Self.symbol(category)).foregroundStyle(.secondary)
                Text(Self.title(category)).font(.headline)
                Text("\(items.count)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 4)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(items) { BoardCard(issue: $0, ready: store.readyIDs.contains($0.id)) }
                }
                .padding(2)
            }
            .scrollIndicators(.hidden)
        }
        .padding(10)
        .frame(minWidth: 240, maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(targeted ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.background),
                    in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(targeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator)))
        .dropDestination(for: String.self) { ids, _ in
            ids.forEach { store.move($0, toCategory: category) }
            return !ids.isEmpty
        } isTargeted: { targeted = $0 }
    }
}

extension BoardColumn {
    static func title(_ c: String) -> String { ["active": "Active", "wip": "In Progress", "done": "Done", "frozen": "Frozen"][c] ?? c.capitalized }
    static func symbol(_ c: String) -> String { ["active": "circle", "wip": "circle.lefthalf.filled", "done": "checkmark.circle.fill", "frozen": "snowflake"][c] ?? "circle" }
}

private struct BoardCard: View {
    @Environment(Store.self) private var store
    let issue: Issue
    let ready: Bool

    /// `bd blocked`: waiting on an unfinished dependency. Independent of status, so an in-progress card can be blocked.
    private var blockers: [String] { store.blockedBy[issue.id] ?? [] }

    var body: some View {
        let selected = store.selection == issue.id
        VStack(alignment: .leading, spacing: 6) {
            Text(issue.title).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                .strikethrough(issue.isClosed).foregroundStyle(issue.isClosed ? .secondary : .primary)
            HStack(spacing: 8) {
                PriorityBadge(priority: issue.priority)
                StatusChip(status: issue.status)
                TypeBadge(type: issue.issueType)
                Spacer(minLength: 0)
                if ready { Image(systemName: "bolt.fill").foregroundStyle(.green).help("Ready to work on") }
                if !blockers.isEmpty {
                    Image(systemName: "lock.fill").foregroundStyle(.red)
                        .help("Blocked by " + blockers.map { store.issue($0)?.title ?? $0 }.joined(separator: ", "))
                }
            }
            if issue.isEpic { let p = store.progress(of: issue.id); EpicProgress(done: p.done, total: p.total) }
            if let pid = issue.parent, let parent = store.issue(pid), !store.epicFilter.contains(pid) {
                Label(parent.title, systemImage: "square.stack.3d.up").font(.caption).lineLimit(1).foregroundStyle(.secondary)
            }
            HStack {
                DueBadge(issue: issue)
                Spacer()
                AssigneeLabel(issue: issue)
            }
            Text(issue.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(issue.isEpic ? AnyShapeStyle(.tint.opacity(0.1)) : AnyShapeStyle(.background.secondary), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selected ? 2 : 1))
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .onTapGesture { store.selection = issue.id }
        .draggable(issue.id)
        .contextMenu { AssigneeActions(issue: issue) }
    }
}
