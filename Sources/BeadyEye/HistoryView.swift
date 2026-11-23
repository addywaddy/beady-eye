import SwiftUI

/// An issue's version history, from `bd history`: each change with what moved ("Status: Open → Closed")
/// and, for long text, a line diff. Loaded only when expanded, and reloaded when the issue changes.
struct HistorySection: View {
    @Environment(Store.self) private var store
    let issue: Issue
    @State private var open = false
    @State private var rows: [HistoryRow] = []
    @State private var complete = true
    @State private var limit = 40
    @State private var loading = false
    @State private var failure: String?
    @State private var loadedOnce = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button { open.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).rotationEffect(.degrees(open ? 90 : 0))
                    Text("HISTORY").font(.caption.weight(.semibold)).tracking(0.6)
                    if open, loadedOnce, failure == nil { Text("\(rows.count) change\(rows.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.tertiary) }
                    Spacer()
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(open ? "Hide history" : "Show history")

            if open { content }
        }
        // Runs when opened and again whenever the issue changes (or more history is requested).
        .task(id: open ? "\(issue.updatedAt ?? "")|\(limit)" : "closed") { if open { await load() } }
    }

    @ViewBuilder private var content: some View {
        if let failure {
            Label(failure, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
            Button("Retry") { Task { await load() } }.controlSize(.small)
        } else if !loadedOnce {
            ProgressView().controlSize(.small)
        } else if rows.isEmpty {
            Text("No recorded changes.").foregroundStyle(.tertiary)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                    HistoryRowView(row: row, isLast: i == rows.count - 1 && complete)
                }
            }
            if !complete {
                Button { limit *= 2 } label: { Label("Load earlier changes", systemImage: "clock.arrow.circlepath") }
                    .controlSize(.small)
            }
        }
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let (entries, events) = try await store.history(for: issue.id, limit: limit)
            let isComplete = entries.count < limit
            complete = isComplete
            rows = historyRows(entries: entries, events: events, complete: isComplete)
            failure = nil
            loadedOnce = true
        } catch {
            failure = error.localizedDescription
        }
    }
}

private struct HistoryRowView: View {
    let row: HistoryRow
    let isLast: Bool

    private var tint: Color {
        switch row.title {
        case "Created", "Closed": .green
        case "Reopened": .orange
        default: .accentColor
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(tint).frame(width: 9, height: 9).padding(.top, 5)
                if !isLast { Rectangle().fill(.separator).frame(width: 1).frame(maxHeight: .infinity) }
            }
            .frame(width: 9)

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.callout.weight(.semibold))
                    HStack(spacing: 6) {
                        if let actor = row.actor { Text(actor) }
                        if let d = row.entry.date {
                            Text(d, format: .relative(presentation: .named)).help(d.formatted(date: .abbreviated, time: .standard))
                        }
                        Text(String(row.entry.commitHash.prefix(7))).font(.caption.monospaced()).textSelection(.enabled)
                            .help("Dolt commit \(row.entry.commitHash)")
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(row.changes) { change in changeView(change) }
            }
            .padding(.bottom, 16)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func changeView(_ c: FieldChange) -> some View {
        switch c.value {
        case .short(let old, let new):
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(c.label).font(.callout).foregroundStyle(.secondary).frame(width: 96, alignment: .leading)
                (Text(old ?? "none").strikethrough(old != nil).foregroundStyle(.secondary)
                 + Text("  →  ").foregroundStyle(.tertiary)
                 + Text(new ?? "none").fontWeight(.medium))
                    .font(.callout).textSelection(.enabled)
                Spacer(minLength: 0)
            }
        case .text(let lines):
            VStack(alignment: .leading, spacing: 4) {
                Text(c.label).font(.callout).foregroundStyle(.secondary)
                DiffBlock(lines: lines)
            }
        }
    }
}

/// A unified line diff: removed lines in red, added in green, unchanged context dimmed, "⋯" where lines were skipped.
private struct DiffBlock: View {
    let lines: [DiffLine]
    @State private var showAll = false
    private let cap = 24

    var body: some View {
        let shown = showAll ? lines : Array(lines.prefix(cap))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(shown) { line in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(line.kind)).foregroundStyle(color(line.kind)).frame(width: 12, alignment: .center)
                    Text(line.kind == .gap ? "" : (line.text.isEmpty ? " " : line.text))
                        .foregroundStyle(line.kind == .same ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 6).padding(.vertical, 1.5)
                .background(background(line.kind))
            }
            if lines.count > cap, !showAll {
                Button("Show \(lines.count - cap) more lines") { showAll = true }
                    .buttonStyle(.borderless).controlSize(.small).padding(6)
            }
        }
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator.opacity(0.6)))
    }

    private func marker(_ k: DiffLine.Kind) -> String {
        switch k { case .added: "+"; case .removed: "−"; case .gap: "⋯"; case .same: "" }
    }
    private func color(_ k: DiffLine.Kind) -> Color {
        switch k { case .added: .green; case .removed: .red; default: .secondary }
    }
    private func background(_ k: DiffLine.Kind) -> Color {
        switch k { case .added: .green.opacity(0.14); case .removed: .red.opacity(0.14); default: .clear }
    }
}
