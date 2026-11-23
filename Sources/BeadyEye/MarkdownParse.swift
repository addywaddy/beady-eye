import Foundation

/// One visual block of a Markdown document. SwiftUI's `Text` can only draw inline styling, so we split the
/// document into blocks (using the structure Apple's parser reports) and let `MarkdownView` draw each one.
struct MarkdownBlock: Identifiable {
    enum Kind: Equatable {
        case paragraph
        case heading(Int)
        case code(String?)
        case rule
        case cell(row: Int, column: Int, header: Bool)
    }

    let id: Int
    var kind: Kind
    var text: AttributedString
    var quoteDepth = 0
    var listDepth = 0
    /// Bullet, number or checkbox for the first block of a list item; "" for its later blocks.
    var marker: String?
}

/// Characters that can appear inside an issue id (`beady-eye-c6o`, `scr-dfy.1`).
private let idBoundary = #"[A-Za-z0-9_\-]"#

func parseMarkdown(_ source: String, linking ids: Set<String> = []) -> [MarkdownBlock] {
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .full
    guard let attributed = try? AttributedString(markdown: source, options: options) else {
        return [MarkdownBlock(id: 0, kind: .paragraph, text: AttributedString(source))]
    }

    var blocks: [MarkdownBlock] = []
    var currentKey: Int?
    var seenItems = Set<Int>()

    for run in attributed.runs {
        let comps = run.presentationIntent?.components ?? []
        let key = comps.first?.identity ?? -1
        var piece = AttributedString(attributed[run.range])
        // A soft break is a single newline in the source. Plain Markdown folds it into a space, but people
        // (and agents) write ticket text line by line, so keep it as a line break.
        if run.inlinePresentationIntent?.contains(.softBreak) == true { piece = AttributedString("\n") }

        if key == currentKey, !blocks.isEmpty {
            blocks[blocks.count - 1].text += piece
            continue
        }
        currentKey = key

        var block = MarkdownBlock(id: key, kind: .paragraph, text: piece)
        var tableRow: Int?
        var isHeaderRow = false
        var column = 0
        for (i, c) in comps.enumerated() {
            switch c.kind {
            case .header(let level) where i == 0: block.kind = .heading(level)
            case .codeBlock(let hint) where i == 0: block.kind = .code(hint)
            case .thematicBreak where i == 0: block.kind = .rule
            case .tableCell(let col): column = col
            case .tableRow: tableRow = tableRow ?? c.identity
            case .tableHeaderRow: tableRow = tableRow ?? c.identity; isHeaderRow = true
            case .blockQuote: block.quoteDepth += 1
            case .orderedList, .unorderedList: block.listDepth += 1
            default: break
            }
        }
        if let row = tableRow { block.kind = .cell(row: row, column: column, header: isHeaderRow) }

        // The innermost list item decides the marker; it goes on the item's first block only.
        if let idx = comps.firstIndex(where: { if case .listItem = $0.kind { return true } else { return false } }),
           case .listItem(let ordinal) = comps[idx].kind {
            let itemID = comps[idx].identity
            if seenItems.insert(itemID).inserted {
                let ordered = comps.dropFirst(idx + 1).first.map { if case .orderedList = $0.kind { return true } else { return false } } ?? false
                block.marker = ordered ? "\(ordinal)." : (block.listDepth > 1 ? "◦" : "•")
            } else {
                block.marker = ""
            }
        }
        blocks.append(block)
    }

    for i in blocks.indices {
        trimTrailingNewlines(&blocks[i])
        applyTaskMarker(&blocks[i])
        if !ids.isEmpty, blocks[i].kind != .rule { linkIssueIDs(in: &blocks[i].text, ids: ids) }
    }
    return blocks
}

private func trimTrailingNewlines(_ b: inout MarkdownBlock) {
    while let last = b.text.characters.last, last == "\n" {
        b.text.removeSubrange(b.text.index(beforeCharacter: b.text.endIndex)..<b.text.endIndex)
    }
}

/// `- [ ] todo` / `- [x] done`: Apple's parser leaves the brackets as text, so turn them into checkboxes.
private func applyTaskMarker(_ b: inout MarkdownBlock) {
    guard b.marker != nil, b.marker != "", b.kind == .paragraph else { return }
    let s = String(b.text.characters)
    let checked: Bool
    if s.hasPrefix("[ ] ") { checked = false } else if s.hasPrefix("[x] ") || s.hasPrefix("[X] ") { checked = true } else { return }
    let start = b.text.startIndex
    let end = b.text.index(start, offsetByCharacters: 4)
    b.text.removeSubrange(start..<end)
    b.marker = checked ? "☑" : "☐"
}

/// Turn mentions of known issue ids into `beadyeye://issue/<id>` links (not inside code or existing links).
private func linkIssueIDs(in text: inout AttributedString, ids: Set<String>) {
    let s = String(text.characters)
    guard s.count >= 3 else { return }
    let alternation = ids.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
    guard let regex = try? NSRegularExpression(pattern: "(?<!\(idBoundary))(\(alternation))(?!\(idBoundary))") else { return }
    let ns = s as NSString
    for m in regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
        guard let r = Range(m.range, in: s),
              let lower = AttributedString.Index(r.lowerBound, within: text),
              let upper = AttributedString.Index(r.upperBound, within: text) else { continue }
        let range = lower..<upper
        let runs = text[range].runs
        if runs.contains(where: { $0.link != nil || $0.inlinePresentationIntent?.contains(.code) == true }) { continue }
        text[range].link = URL(string: "beadyeye://issue/\(ns.substring(with: m.range))")
    }
}
