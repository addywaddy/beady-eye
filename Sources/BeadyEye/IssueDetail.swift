import SwiftUI

struct IssueDetail: View {
    @Environment(Store.self) private var store
    let issue: Issue
    @State private var title = ""
    @State private var desc = ""
    @State private var editingDesc = false
    @State private var newComment = ""
    @State private var newLabel = ""
    @State private var askOtherName = false
    @State private var otherName = ""
    @State private var closeReason = ""
    @State private var showClose = false
    @State private var confirmDelete = false
    @FocusState private var titleFocused: Bool

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if issue.isClosed { closedNote }
                if store.isBlocked(issue) { blockedNote }
                properties
                descriptionSection
                if issue.isEpic { children }
                // The parent is edited under Epic in the properties card; keep it out of the blocking lists.
                relations("Depends on", issue.dependencies?.filter { $0.dependencyType != "parent-child" })
                relations("Blocks", issue.dependents?.filter { $0.dependencyType != "parent-child" })
                if let n = issue.notes, !n.isEmpty {
                    section("Notes") { card { rich(n) } }
                }
                comments
                Divider()
                HistorySection(issue: issue)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { title = issue.title; desc = issue.description ?? "" }
        // Follow changes made elsewhere (an agent, the CLI) unless you're mid-edit.
        .onChange(of: issue.title) { _, new in if !titleFocused { title = new } }
        .onChange(of: issue.description) { _, new in if !editingDesc { desc = new ?? "" } }
        .sheet(isPresented: $showClose) { closeSheet }
        .confirmationDialog("Delete “\(issue.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { store.delete(issue.id) }
        } message: { Text(deleteWarning) }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text(issue.id).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                TypeBadge(type: issue.issueType)
                if let c = issue.createdAt?.beadsDate {
                    Text("Created \(c, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.tertiary)
                }
                Spacer()
                if issue.isClosed {
                    Button("Reopen") { store.reopen(issue.id) }
                } else {
                    Button("Close…") { showClose = true }
                }
                Button { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help("Delete this issue permanently")
            }
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain).font(.title.bold())
                .focused($titleFocused)
                .onSubmit(commitTitle)
                .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
        }
    }

    /// bd removes the issue and its links for good; say what else it touches.
    private var deleteWarning: String {
        var parts = ["This permanently deletes \(issue.id) and can't be undone from the app."]
        let blocks = (issue.dependents ?? []).filter { $0.dependencyType != "parent-child" }.count
        let kids = store.children(of: issue.id).count
        if blocks > 0 { parts.append("\(blocks) other issue\(blocks == 1 ? "" : "s") depend\(blocks == 1 ? "s" : "") on it and will lose that link.") }
        if kids > 0 { parts.append("\(kids) child issue\(kids == 1 ? "" : "s") will no longer have a parent.") }
        return parts.joined(separator: " ")
    }

    private func commitTitle() {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { title = issue.title } else if t != issue.title { store.setTitle(issue.id, t) }
    }

    @ViewBuilder private var closedNote: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                if let d = issue.closedAt?.beadsDate {
                    Text("Closed \(d, format: .relative(presentation: .named))").font(.callout.weight(.medium))
                } else {
                    Text("Closed").font(.callout.weight(.medium))
                }
                if let r = issue.closeReason, !r.isEmpty { Text(r).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Mirrors `bd blocked`: the unfinished issues this one is waiting on.
    @ViewBuilder private var blockedNote: some View {
        let ids = store.blockedBy[issue.id] ?? []
        VStack(alignment: .leading, spacing: 6) {
            Label("Blocked by", systemImage: "lock.fill").font(.callout.weight(.medium)).foregroundStyle(.red)
            ForEach(ids, id: \.self) { id in
                Button { store.selection = id } label: {
                    HStack(spacing: 8) {
                        if let b = store.issue(id) { StatusIcon(status: b.status) }
                        Text(store.issue(id)?.title ?? id).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Properties

    private var properties: some View {
        card {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 12) {
                propertyRow("Status") {
                    Picker("Status", selection: Binding(get: { issue.status }, set: { store.setStatus(issue.id, $0) })) {
                        // bd's own statuses; keep the current one selectable even if bd no longer lists it.
                        ForEach(store.statuses.contains { $0.name == issue.status } ? store.statuses : store.statuses + [StatusInfo.named(issue.status)]) {
                            Label($0.label, systemImage: $0.symbol).tag($0.name)
                        }
                    }.labelsHidden().fixedSize()
                }
                propertyRow("Priority") {
                    Picker("Priority", selection: Binding(get: { issue.priority }, set: { store.setPriority(issue.id, $0) })) {
                        ForEach(0...4, id: \.self) { Text("P\($0)").tag($0) }
                    }.labelsHidden().fixedSize()
                }
                propertyRow("Assignee") { assigneeControls }
                propertyRow("Due") { dueControls }
                if !issue.isClosed { propertyRow("Defer") { deferControls } }
                if !issue.isEpic || issue.parent != nil {
                    propertyRow("Epic") { epicControl }
                }
                propertyRow("Labels") { labelControls }
            }
        }
    }

    private func propertyRow<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        GridRow {
            Text(name).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The assignee is shown, not typed: it always reflects the issue, and changes only through the menu.
    private var assigneeControls: some View {
        let name = issue.assignee ?? ""
        return HStack(spacing: 8) {
            if name.isEmpty {
                Text("Unassigned").foregroundStyle(.secondary)
                if !issue.isClosed {
                    let open = issue.status == "open"
                    Button { store.claim(issue.id) } label: {
                        Label(open ? "Claim and Start" : "Assign to Me", systemImage: open ? "hand.raised" : "person.crop.circle")
                    }
                    .controlSize(.small)
                    .help(open ? "Assign to \(store.me ?? "you") and move to In Progress" : "Assign to \(store.me ?? "you")")
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Label(store.isMine(issue) ? "\(name) (you)" : name, systemImage: store.isMine(issue) ? "person.fill" : "person")
                        .foregroundStyle(store.isMine(issue) ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    if store.isMine(issue), let email = store.meEmail {
                        Text(email).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                            .padding(.leading, 22)
                    }
                }
            }
            Spacer(minLength: 4)
            Menu {
                if let me = store.me, name != me {
                    Button("Me (\(me))") { store.setAssignee(issue.id, me) }
                }
                ForEach(store.otherAssignees.filter { $0 != name }, id: \.self) { a in
                    Button(a) { store.setAssignee(issue.id, a) }
                }
                Divider()
                Button("Someone else…") { otherName = ""; askOtherName = true }
            } label: { Image(systemName: "person.crop.circle.badge.plus") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("Change assignee")
            if !name.isEmpty {
                Button { CallLog.write("UI: unassign tapped for \(issue.id)"); store.setAssignee(issue.id, "") } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.large)
                        .frame(width: 24, height: 24).contentShape(Rectangle())   // generous click target
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Unassign")
            }
        }
        .alert("Assign to", isPresented: $askOtherName) {
            TextField("Name", text: $otherName)
            Button("Assign") {
                let n = otherName.trimmingCharacters(in: .whitespaces)
                if !n.isEmpty { store.setAssignee(issue.id, n) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Enter the name exactly as it should be recorded in bd.") }
    }

    @State private var pickDeferDate = false
    @State private var deferPick = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now

    private var deferControls: some View {
        HStack(spacing: 8) {
            if issue.status == "deferred" {
                if let d = issue.deferDate {
                    Label("Until \(d.formatted(.dateTime.month(.abbreviated).day().year()))", systemImage: "clock")
                } else {
                    Label("Until undeferred", systemImage: "snowflake").foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button("Undefer") { store.undefer(issue.id) }.controlSize(.small)
            } else {
                Text("Not deferred").foregroundStyle(.secondary)
                Menu("Defer…") {
                    Button("Tomorrow") { store.defer_(issue.id, until: day(1)) }
                    Button("Next week") { store.defer_(issue.id, until: day(7)) }
                    Button("Next month") { store.defer_(issue.id, until: Calendar.current.date(byAdding: .month, value: 1, to: .now)) }
                    Button("Choose a date…") { pickDeferDate = true }
                    Divider()
                    Button("Until I undefer it") { store.defer_(issue.id, until: nil) }
                }
                .menuStyle(.borderlessButton).fixedSize()
                .popover(isPresented: $pickDeferDate) {
                    VStack(spacing: 10) {
                        DatePicker("Defer until", selection: $deferPick, in: Date.now..., displayedComponents: .date)
                            .datePickerStyle(.graphical).labelsHidden()
                        HStack {
                            Button("Cancel") { pickDeferDate = false }
                            Spacer()
                            Button("Defer") { store.defer_(issue.id, until: deferPick); pickDeferDate = false }
                                .keyboardShortcut(.defaultAction)
                        }
                    }
                    .padding(14).frame(width: 260)
                }
            }
        }
    }

    private func day(_ n: Int) -> Date? { Calendar.current.date(byAdding: .day, value: n, to: .now) }

    private var dueControls: some View {
        HStack(spacing: 8) {
            if let due = issue.dueDate {
                DatePicker("Due", selection: Binding(get: { due }, set: { store.setDue(issue.id, $0) }), displayedComponents: .date)
                    .labelsHidden().datePickerStyle(.field).fixedSize()
                if issue.isOverdue { Text("Overdue").font(.caption.bold()).foregroundStyle(.red) }
                Spacer(minLength: 4)
                Button { store.setDue(issue.id, nil) } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.large).frame(width: 24, height: 24).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear due date")
            } else {
                Text("No due date").foregroundStyle(.secondary)
                Button("Set…") { store.setDue(issue.id, Calendar.current.date(byAdding: .day, value: 1, to: .now)) }
                    .controlSize(.small)
            }
        }
    }

    private var epicControl: some View {
        Menu {
            Button("None") { store.setParent(issue.id, nil) }
            Divider()
            ForEach(store.epics.filter { $0.id != issue.id }) { e in
                Button(e.title) { store.setParent(issue.id, e.id) }
            }
        } label: {
            Label(issue.parent.flatMap { store.issue($0)?.title } ?? issue.parent ?? "None", systemImage: "square.stack.3d.up")
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    private var labelControls: some View {
        FlowLayout(spacing: 6) {
            ForEach(issue.labels ?? [], id: \.self) { l in
                HStack(spacing: 4) {
                    Text(l)
                    Button { store.removeLabel(issue.id, l) } label: { Image(systemName: "xmark") .font(.system(size: 8, weight: .bold)) }
                        .buttonStyle(.plain)
                }
                .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                .background(.tint.opacity(0.15), in: Capsule())
            }
            TextField("Add label", text: $newLabel)
                .textFieldStyle(.plain).font(.caption).frame(width: 80)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .overlay(Capsule().strokeBorder(.separator))
                .onSubmit {
                    let l = newLabel.trimmingCharacters(in: .whitespaces)
                    guard !l.isEmpty else { return }
                    store.addLabel(issue.id, l); newLabel = ""
                }
        }
    }

    // MARK: Description

    private var descriptionSection: some View {
        section("Description", trailing: {
            if !editingDesc {
                Button { desc = issue.description ?? ""; editingDesc = true } label: {
                    Label((issue.description ?? "").isEmpty ? "Add" : "Edit", systemImage: "pencil")
                }
                .buttonStyle(.borderless).controlSize(.small).help("Edit description")
            }
        }) {
            if editingDesc {
                VStack(alignment: .trailing, spacing: 8) {
                    TextEditor(text: $desc)
                        .font(.body).frame(minHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(8).background(.background, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.tint))
                    HStack {
                        Button("Cancel") { desc = issue.description ?? ""; editingDesc = false }.help("Discard changes")
                        Button("Save") { store.setDescription(issue.id, desc); editingDesc = false }
                            .keyboardShortcut(.return, modifiers: .command)
                            .buttonStyle(.borderedProminent).help("Save description (⌘↩)")
                    }
                }
            } else if let d = issue.description, !d.isEmpty {
                card { rich(d) }
            } else {
                Text("No description.").foregroundStyle(.tertiary)
            }
        }
    }

    // MARK: Relations

    private var children: some View {
        let kids = store.children(of: issue.id)
        let p = store.progress(of: issue.id)
        return section("Child issues", trailing: { EpicProgress(done: p.done, total: p.total) }) {
            if kids.isEmpty {
                Text("No child issues yet.").foregroundStyle(.tertiary)
            } else {
                card(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(kids) { k in
                            Button { store.selection = k.id } label: {
                                HStack(spacing: 8) {
                                    StatusIcon(status: k.status)
                                    Text(k.title).lineLimit(2).strikethrough(k.isClosed).foregroundStyle(k.isClosed ? .secondary : .primary)
                                    Spacer(minLength: 6)
                                    AssigneeLabel(issue: k)
                                    DueBadge(issue: k)
                                    DeferBadge(issue: k)
                                    PriorityBadge(priority: k.priority)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if k.id != kids.last?.id { Divider() }
                        }
                    }
                }
            }
            Button { store.presentNewIssue(parent: issue.id) } label: { Label("Add Child Issue", systemImage: "plus") }
                .controlSize(.small)
        }
    }

    @ViewBuilder
    private func relations(_ name: String, _ items: [Related]?) -> some View {
        if let items, !items.isEmpty {
            section(name) {
                card(padding: 4) {
                    VStack(spacing: 0) {
                        ForEach(items) { r in
                            Button { store.selection = r.id } label: {
                                HStack(spacing: 8) {
                                    StatusIcon(status: r.status)
                                    Text(r.title).lineLimit(2)
                                    Spacer(minLength: 6)
                                    Text(r.id).font(.caption.monospaced()).foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if r.id != items.last?.id { Divider() }
                        }
                    }
                }
            }
        }
    }

    // MARK: Comments

    private var comments: some View {
        let list = issue.comments ?? []
        return section(list.isEmpty ? "Comments" : "Comments (\(list.count))") {
            ForEach(list) { c in
                HStack(alignment: .top, spacing: 10) {
                    Text(initials(c.author))
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26).background(.tint, in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text(c.author ?? "unknown").font(.callout.weight(.semibold))
                            if let d = c.createdAt?.beadsDate { Text(d, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary) }
                        }
                        rich(c.text, compact: true)
                    }
                    Spacer(minLength: 0)
                }
            }
            VStack(alignment: .trailing, spacing: 6) {
                TextEditor(text: $newComment)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(minHeight: 70, maxHeight: 200)
                    .background(.background, in: RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                    .overlay(alignment: .topLeading) {
                        if newComment.isEmpty {
                            Text("Add a comment… (Return for a new line, ⌘↩ to post)")
                                .foregroundStyle(.tertiary).padding(.horizontal, 11).padding(.vertical, 6).allowsHitTesting(false)
                        }
                    }
                Button("Post") {
                    store.comment(issue.id, newComment.trimmingCharacters(in: .whitespacesAndNewlines))
                    newComment = ""
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }

    private func initials(_ name: String?) -> String {
        let parts = (name ?? "?").split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }

    private var closeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Close \(issue.id)").font(.headline)
            TextField("Reason (optional)", text: $closeReason).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { showClose = false }
                Button("Close Issue") { store.close(issue.id, reason: closeReason); closeReason = ""; showClose = false }
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 380)
    }

    // MARK: Building blocks

    /// Quiet, consistent section header; optional control on the right.
    private func section<C: View, T: View>(_ name: String, @ViewBuilder trailing: () -> T = { EmptyView() }, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(name.uppercased()).font(.caption.weight(.semibold)).tracking(0.6).foregroundStyle(.secondary)
                Spacer()
                trailing()
            }
            content()
        }
    }

    private func card<C: View>(padding: CGFloat = 12, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator.opacity(0.6)))
    }

    /// Markdown from bd (descriptions, notes, comments), drawn block by block.
    private func rich(_ s: String, compact: Bool = false) -> some View { MarkdownView(source: s, compact: compact) }
}

struct NewIssueSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type = "task"
    @State private var priority = 2
    @State private var desc = ""
    @State private var assignee = ""
    @State private var hasDue = false
    @State private var due = Calendar.current.date(byAdding: .day, value: 7, to: .now) ?? .now
    @State private var parent = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Issue").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Type", selection: $type) { ForEach(store.types, id: \.self) { Text($0.capitalized).tag($0) } }
                Picker("Priority", selection: $priority) { ForEach(0...4, id: \.self) { Text("P\($0)").tag($0) } }
            }
            HStack {
                TextField("Assignee", text: $assignee).textFieldStyle(.roundedBorder)
                Picker("Epic", selection: $parent) {
                    Text("None").tag("")
                    ForEach(store.epics) { Text($0.title).tag($0.id) }
                }
            }
            HStack {
                Toggle("Due", isOn: $hasDue)
                DatePicker("Due", selection: $due, displayedComponents: .date).labelsHidden().disabled(!hasDue)
                Spacer()
            }
            TextEditor(text: $desc).frame(height: 110)
                .padding(4).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    store.create(title: title, type: type, priority: priority, description: desc,
                                 assignee: assignee.trimmingCharacters(in: .whitespaces),
                                 due: hasDue ? due : nil, parent: parent.isEmpty ? nil : parent)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .onAppear { parent = store.newIssueParent ?? "" }
    }
}
