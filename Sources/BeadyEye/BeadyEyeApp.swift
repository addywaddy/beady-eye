import SwiftUI

@main
struct BeadyEyeApp: App {
    @State private var store = Store()
    @State private var showNew = false

    var body: some Scene {
        WindowGroup {
            ContentView(showNew: $showNew)
                .environment(store)
                .frame(minWidth: 900, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Issue…") { showNew = true }
                    .keyboardShortcut("n")
                    .disabled(store.workspace == nil)
                Button("Add Connection…") { store.addConnectionWithPanel() }
                    .keyboardShortcut("o")
                Menu("Switch Connection") {
                    ForEach(store.connections) { c in
                        Button { store.activeID = c.id } label: {
                            if c.id == store.activeID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                        }
                    }
                }
                .disabled(store.connections.isEmpty)
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }
}
