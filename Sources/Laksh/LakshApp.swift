import SwiftUI

@main
struct LakshApp: App {
    @StateObject private var store = SessionStore()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup("Laksh") {
            RootView()
                .environmentObject(store)
                .frame(minWidth: 1000, minHeight: 640)
                .task { store.refreshDetectedAgents() }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Task…") { store.requestNewTaskSheet() }
                    .keyboardShortcut("n", modifiers: [.command])
            }
            CommandGroup(after: .toolbar) {
                Button("Close Session") { store.closeActiveSession() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
            CommandGroup(after: .windowArrangement) {
                Divider()
                Button("Native Terminal") {
                    openWindow(id: "terminal-demo")
                }
                .keyboardShortcut("d", modifiers: [.command, .option])
            }
        }

        Window("Native Terminal", id: "terminal-demo") {
            TerminalDemo()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.titleBar)
    }
}
