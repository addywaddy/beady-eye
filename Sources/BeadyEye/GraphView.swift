import SwiftUI

/// Layered left-to-right layout: an issue sits one layer to the right of everything it depends on,
/// so column 0 is what can start now (same convention as `bd graph`).
struct GraphLayout {
    static let nodeSize = CGSize(width: 230, height: 64)
    static let hGap: CGFloat = 90, vGap: CGFloat = 18, pad: CGFloat = 32

    struct Edge { let from: String, to: String, blocking: Bool }

    var centers: [String: CGPoint] = [:]
    var issues: [String: Issue] = [:]
    var edges: [Edge] = []
    var size: CGSize = .zero
    var hidden = 0

    init(all: [Issue], showClosed: Bool, connectedOnly: Bool) {
        let pool = all.filter { showClosed || !$0.isClosed }
        let ids = Set(pool.map(\.id))
        issues = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, $0) })

        // issue depends on dep  =>  edge dep -> issue
        for i in pool {
            for d in i.dependencies ?? [] where ids.contains(d.id) && d.id != i.id {
                edges.append(Edge(from: d.id, to: i.id, blocking: (d.dependencyType ?? "blocks") == "blocks"))
            }
        }
        let connected = Set(edges.flatMap { [$0.from, $0.to] })
        let nodes = pool.filter { !connectedOnly || connected.contains($0.id) }
        hidden = pool.count - nodes.count
        let nodeIDs = Set(nodes.map(\.id))
        edges = edges.filter { nodeIDs.contains($0.from) && nodeIDs.contains($0.to) }

        var depsOf: [String: [String]] = [:]
        for e in edges { depsOf[e.to, default: []].append(e.from) }

        // Longest-path layering; `visiting` breaks any dependency cycle.
        var layerOf: [String: Int] = [:]
        var visiting = Set<String>()
        func layer(_ id: String) -> Int {
            if let l = layerOf[id] { return l }
            guard visiting.insert(id).inserted else { return 0 }
            let l = (depsOf[id] ?? []).map { layer($0) + 1 }.max() ?? 0
            visiting.remove(id)
            layerOf[id] = l
            return l
        }
        nodes.forEach { _ = layer($0.id) }

        var layers = [[Issue]](repeating: [], count: (layerOf.values.max() ?? -1) + 1)
        for n in nodes { layers[layerOf[n.id] ?? 0].append(n) }
        var row: [String: Double] = [:]
        for l in layers.indices {
            // Order by the average row of dependencies (fewer crossings), then priority.
            layers[l].sort {
                let a = (depsOf[$0.id] ?? []).compactMap { row[$0] }, b = (depsOf[$1.id] ?? []).compactMap { row[$0] }
                let ma = a.isEmpty ? Double.infinity : a.reduce(0, +) / Double(a.count)
                let mb = b.isEmpty ? Double.infinity : b.reduce(0, +) / Double(b.count)
                if ma != mb { return ma < mb }
                return ($0.priority, $0.id) < ($1.priority, $1.id)
            }
            for (i, n) in layers[l].enumerated() { row[n.id] = Double(i) }
        }

        let w = Self.nodeSize.width, h = Self.nodeSize.height
        let tallest = layers.map(\.count).max() ?? 0
        for (l, col) in layers.enumerated() {
            let offset = CGFloat(tallest - col.count) * (h + Self.vGap) / 2   // centre short columns
            for (i, n) in col.enumerated() {
                centers[n.id] = CGPoint(x: Self.pad + w / 2 + CGFloat(l) * (w + Self.hGap),
                                        y: Self.pad + h / 2 + offset + CGFloat(i) * (h + Self.vGap))
            }
        }
        size = CGSize(width: Self.pad * 2 + CGFloat(layers.count) * w + CGFloat(max(layers.count - 1, 0)) * Self.hGap,
                      height: Self.pad * 2 + CGFloat(tallest) * h + CGFloat(max(tallest - 1, 0)) * Self.vGap)
    }
}

struct GraphView: View {
    @Environment(Store.self) private var store
    @AppStorage("graphShowClosed") private var showClosed = false
    @AppStorage("graphConnectedOnly") private var connectedOnly = true

    var body: some View {
        // Picking Closed or All in the sidebar means "include closed issues".
        let wantsClosed = showClosed || store.sidebar == .filter(.closed) || store.sidebar == .filter(.all)
        let g = GraphLayout(all: store.scoped.filter(store.matchesSearch), showClosed: wantsClosed, connectedOnly: connectedOnly)
        VStack(spacing: 0) {
            RefreshBanner()
            HStack(spacing: 16) {
                Toggle("Connected only", isOn: $connectedOnly)
                Toggle("Show closed", isOn: $showClosed)
                if g.hidden > 0 { Text("\(g.hidden) unconnected hidden").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Text("Arrows point from a dependency to the issue it blocks").font(.caption).foregroundStyle(.tertiary)
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 16).padding(.vertical, 8)
            Divider()
            if g.centers.isEmpty {
                ContentUnavailableView("Nothing to Graph", systemImage: "point.3.connected.trianglepath.dotted",
                                       description: Text(connectedOnly ? "No issues have dependencies yet. Turn off “Connected only” to see every issue." : "No issues."))
            } else {
                ScrollView([.horizontal, .vertical]) {
                    ZStack(alignment: .topLeading) {
                        GraphEdges(layout: g, selection: store.selection).frame(width: g.size.width, height: g.size.height)
                        ForEach(Array(g.centers), id: \.key) { id, c in
                            if let issue = g.issues[id] {
                                GraphNode(issue: issue, ready: store.readyIDs.contains(id), selected: store.selection == id)
                                    .frame(width: GraphLayout.nodeSize.width, height: GraphLayout.nodeSize.height)
                                    .position(c)
                                    .onTapGesture { store.selection = id }
                            }
                        }
                    }
                    .frame(width: g.size.width, height: g.size.height)
                }
                .background(.background.secondary)
            }
        }
    }
}

private struct GraphEdges: View {
    let layout: GraphLayout
    let selection: String?

    var body: some View {
        Canvas { ctx, _ in
            let w = GraphLayout.nodeSize.width
            for e in layout.edges {
                guard let a = layout.centers[e.from], let b = layout.centers[e.to] else { continue }
                let p1 = CGPoint(x: a.x + w / 2, y: a.y), p2 = CGPoint(x: b.x - w / 2, y: b.y)
                let dx = max(40, abs(p2.x - p1.x) / 2)
                var path = Path()
                path.move(to: p1)
                path.addCurve(to: p2, control1: CGPoint(x: p1.x + dx, y: p1.y), control2: CGPoint(x: p2.x - dx, y: p2.y))
                let active = selection != nil && (e.from == selection || e.to == selection)
                let color: Color = active ? .accentColor : .secondary.opacity(0.7)
                ctx.stroke(path, with: .color(color),
                           style: StrokeStyle(lineWidth: active ? 2.5 : 1.5, lineCap: .round, dash: e.blocking ? [] : [5, 4]))
                var head = Path()
                head.move(to: p2)
                head.addLine(to: CGPoint(x: p2.x - 9, y: p2.y - 5))
                head.addLine(to: CGPoint(x: p2.x - 9, y: p2.y + 5))
                head.closeSubpath()
                ctx.fill(head, with: .color(color))
            }
        }
    }
}

private struct GraphNode: View {
    let issue: Issue
    let ready: Bool
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusIcon(status: issue.status).padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(issue.title).font(.callout).lineLimit(2).strikethrough(issue.isClosed)
                    .foregroundStyle(issue.isClosed ? .secondary : .primary)
                HStack(spacing: 6) {
                    Text(issue.id).font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    if ready { Image(systemName: "bolt.fill").font(.caption2).foregroundStyle(.green) }
                }
            }
            Spacer(minLength: 0)
            PriorityBadge(priority: issue.priority)
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: selected ? 2.5 : 1))
        .shadow(color: .black.opacity(0.08), radius: 2, y: 1)
    }
}
