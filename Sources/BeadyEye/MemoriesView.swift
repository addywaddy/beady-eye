import SwiftUI

/// What `bd remember` has stored (the notes `bd prime` hands to every agent session).
struct MemoriesView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    @State private var adding = false
    @State private var newKey = ""
    @State private var newText = ""
    @State private var editing: Memory?
    @State private var editText = ""
    @State private var pendingForget: Memory?

    private var shown: [Memory] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? store.memories : store.memories.filter { $0.key.lowercased().contains(q) || $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Memories").font(.title2.bold())
                Text("\(store.memories.count)").foregroundStyle(.secondary)
                Spacer()
                Button { adding.toggle() } label: { Label("Add", systemImage: "plus") }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            TextField("Search memories", text: $search).textFieldStyle(.roundedBorder).padding(.horizontal, 16).padding(.bottom, 10)
            if let e = store.memoriesError {
                Text(e).font(.callout).foregroundStyle(.red).padding(.horizontal, 16).padding(.bottom, 8).textSelection(.enabled)
            }
            if adding { addForm }
            Divider()
            if shown.isEmpty {
                ContentUnavailableView(store.memories.isEmpty ? "No memories yet" : "No matches",
                                       systemImage: "brain",
                                       description: Text(store.memories.isEmpty ? "Agents store notes here with `bd remember`." : "Try a different search."))
                    .frame(maxHeight: .infinity)
            } else {
                List(shown) { m in row(m) }
            }
        }
        .frame(width: 560, height: 520)
        .task { await store.loadMemories() }
        .confirmationDialog("Forget “\(pendingForget?.key ?? "")”?", isPresented: Binding(get: { pendingForget != nil }, set: { if !$0 { pendingForget = nil } })) {
            Button("Forget", role: .destructive) { if let m = pendingForget { store.forget(m.key) }; pendingForget = nil }
        } message: { Text("This removes the memory with bd forget.") }
    }

    private var addForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Key (optional; generated from the text if empty)", text: $newKey).textFieldStyle(.roundedBorder)
            TextEditor(text: $newText).font(.body).frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Cancel") { adding = false; newKey = ""; newText = "" }
                Button("Remember") {
                    store.remember(newText.trimmingCharacters(in: .whitespacesAndNewlines), key: newKey.isEmpty ? nil : newKey)
                    adding = false; newKey = ""; newText = ""
                }
                .disabled(newText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 12)
    }

    @ViewBuilder private func row(_ m: Memory) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(m.key).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                if editing?.key == m.key {
                    Button("Cancel") { editing = nil }
                    Button("Save") { store.remember(editText, key: m.key); editing = nil }
                        .disabled(editText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button { editText = m.text; editing = m } label: { Image(systemName: "pencil") }.buttonStyle(.borderless).help("Edit")
                    Button { pendingForget = m } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Forget")
                }
            }
            if editing?.key == m.key {
                TextEditor(text: $editText).font(.body).frame(height: 90)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
            } else {
                MarkdownView(source: m.text, compact: true).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 4)
    }
}
