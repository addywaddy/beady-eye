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
                Button("Open Project…") { store.chooseWorkspace() }
                    .keyboardShortcut("o")
                Menu("Open Recent") {
                    ForEach(store.recents, id: \.self) { url in
                        Button(url.lastPathComponent) { store.workspace = url }
                    }
                }
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
            }
        }
    }
}
