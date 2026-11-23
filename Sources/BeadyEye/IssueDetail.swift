import SwiftUI

struct IssueDetail: View {
    @Environment(Store.self) private var store
    let issue: Issue
    @State private var title = ""
    @State private var desc = ""
    @State private var newComment = ""
    @State private var newLabel = ""
    @State private var closeReason = ""
    @State private var showClose = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                controls
                section("Description") {
                    TextEditor(text: $desc)
                        .font(.body).frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: desc) { _, _ in }
                    HStack {
                        Spacer()
                        Button("Save Description") { store.setDescription(issue.id, desc) }
                            .disabled(desc == (issue.description ?? ""))
                    }
                }
                labels
                relations("Depends on", issue.dependencies)
                relations("Blocks", issue.dependents)
                if let n = issue.notes, !n.isEmpty { section("Notes") { Text(n).textSelection(.enabled) } }
                comments
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { title = issue.title; desc = issue.description ?? "" }
        .sheet(isPresented: $showClose) { closeSheet }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text(issue.id).font(.callout.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                TypeBadge(type: issue.issueType)
                if let c = issue.createdAt?.beadsDate { Text("Created \(c, format: .relative(presentation: .named))").font(.caption).foregroundStyle(.tertiary) }
            }
            TextField("Title", text: $title, axis: .vertical)
                .textFieldStyle(.plain).font(.title.bold())
                .onSubmit { if title != issue.title { store.setTitle(issue.id, title) } }
        }
    }

    private var controls: some View {
        HStack(spacing: 14) {
            Picker("Status", selection: Binding(get: { issue.status }, set: { store.setStatus(issue.id, $0) })) {
                ForEach(Status.allCases) { Text($0.label).tag($0.rawValue) }
            }.fixedSize()
            Picker("Priority", selection: Binding(get: { issue.priority }, set: { store.setPriority(issue.id, $0) })) {
                ForEach(0...4, id: \.self) { Text("P\($0)").tag($0) }
            }.fixedSize()
            Spacer()
            if issue.isClosed {
                Button("Reopen") { store.reopen(issue.id) }
            } else {
                Button("Close…") { showClose = true }
            }
        }
    }

    private var labels: some View {
        section("Labels") {
            HStack {
                ForEach(issue.labels ?? [], id: \.self) { l in
                    HStack(spacing: 3) {
                        Text(l)
                        Button { store.removeLabel(issue.id, l) } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                    }
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: Capsule())
                }
                TextField("Add label", text: $newLabel)
                    .textFieldStyle(.roundedBorder).frame(width: 120)
                    .onSubmit {
                        let l = newLabel.trimmingCharacters(in: .whitespaces)
                        guard !l.isEmpty else { return }
                        store.addLabel(issue.id, l); newLabel = ""
                    }
            }
        }
    }

    @ViewBuilder
    private func relations(_ name: String, _ items: [Related]?) -> some View {
        if let items, !items.isEmpty {
            section(name) {
                ForEach(items) { r in
                    Button { store.selection = r.id } label: {
                        HStack { StatusIcon(status: r.status); Text(r.title); Text(r.id).font(.caption.monospaced()).foregroundStyle(.tertiary) }
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var comments: some View {
        section("Comments") {
            ForEach(issue.comments ?? []) { c in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(c.author ?? "unknown").font(.caption.bold())
                        if let d = c.createdAt?.beadsDate { Text(d, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary) }
                    }
                    Text(c.text).textSelection(.enabled)
                }
                .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(alignment: .bottom) {
                TextField("Add a comment…", text: $newComment, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(1...5)
                Button("Post") { store.comment(issue.id, newComment); newComment = "" }
                    .disabled(newComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
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

    private func section<C: View>(_ name: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

struct NewIssueSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var type = "task"
    @State private var priority = 2
    @State private var desc = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Issue").font(.headline)
            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            HStack {
                Picker("Type", selection: $type) { ForEach(issueTypes, id: \.self) { Text($0.capitalized).tag($0) } }
                Picker("Priority", selection: $priority) { ForEach(0...4, id: \.self) { Text("P\($0)").tag($0) } }
            }
            TextEditor(text: $desc).frame(height: 110)
                .padding(4).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Create") {
                    store.create(title: title, type: type, priority: priority, description: desc)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(20).frame(width: 440)
    }
}
