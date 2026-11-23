import SwiftUI

/// Renders Markdown from a bd description, note or comment: headings, lists, task lists, quotes, code blocks
/// and tables, plus inline styling. Mentions of other issues' ids become links that select that issue.
/// The text itself is never rewritten; editing always shows the raw source.
struct MarkdownView: View {
    @Environment(Store.self) private var store
    let source: String
    var compact = false

    private enum Item: Identifiable {
        case block(MarkdownBlock)
        case row(id: Int, header: Bool, cells: [MarkdownBlock])
        var id: Int {
            switch self {
            case .block(let b): b.id
            case .row(let id, _, _): id
            }
        }
    }

    /// Consecutive table cells that share a row become one row.
    private func items(_ blocks: [MarkdownBlock]) -> [Item] {
        var out: [Item] = []
        for b in blocks {
            if case .cell(let row, _, let header) = b.kind {
                if case .row(let id, let h, var cells)? = out.last, id == row {
                    cells.append(b)
                    out[out.count - 1] = .row(id: id, header: h, cells: cells)
                } else {
                    out.append(.row(id: row, header: header, cells: [b]))
                }
            } else {
                out.append(.block(b))
            }
        }
        return out
    }

    var body: some View {
        let blocks = parseMarkdown(source, linking: Set(store.issues.map(\.id)))
        VStack(alignment: .leading, spacing: compact ? 5 : 9) {
            ForEach(items(blocks)) { item in
                switch item {
                case .block(let b): block(b)
                case .row(_, let header, let cells): tableRow(cells, header: header)
                }
            }
        }
        .font(compact ? .callout : .body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == "beadyeye", url.host == "issue" else { return .systemAction }
            store.selection = url.lastPathComponent
            return .handled
        })
    }

    // MARK: Blocks

    @ViewBuilder private func block(_ b: MarkdownBlock) -> some View {
        switch b.kind {
        case .rule:
            Divider().padding(.vertical, 4)
        case .heading(let level):
            Text(b.text).font(headingFont(level)).padding(.top, level <= 2 ? 6 : 2)
        case .code:
            Text(b.text)
                .font(.system(compact ? .caption : .callout, design: .monospaced))
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                .padding(.leading, listIndent(b))
        default:
            listAndQuote(b) { Text(b.text) }
        }
    }

    private func listIndent(_ b: MarkdownBlock) -> CGFloat { CGFloat(max(b.listDepth - 1, 0)) * 18 }

    /// Adds a bullet/number/checkbox on the left and a bar for quotes, indented by nesting depth.
    @ViewBuilder private func listAndQuote<C: View>(_ b: MarkdownBlock, @ViewBuilder _ content: () -> C) -> some View {
        let inner = HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let marker = b.marker {
                Text(marker).foregroundStyle(.secondary).frame(minWidth: 18, alignment: .trailing)
            }
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, listIndent(b))
        if b.quoteDepth > 0 {
            inner
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(.secondary.opacity(0.5)).frame(width: 3) }
        } else {
            inner
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }

    // MARK: Tables

    private func tableRow(_ cells: [MarkdownBlock], header: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(cells) { c in
                Text(c.text).fontWeight(header ? .semibold : .regular)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(header ? AnyShapeStyle(.quaternary.opacity(0.6)) : AnyShapeStyle(.clear))
        .overlay(alignment: .bottom) { Divider() }
    }
}
