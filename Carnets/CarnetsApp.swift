import SwiftUI

// MARK: - Carnets
// Three apps in one, one tab each, stored in one Obsidian-compatible vault:
//  • Carnets    — GoodNotes-style handwriting: Apple Pencil, paper templates, PDF annotation,
//                 shape snapping, laser pointer, on-device handwriting recognition.
//                 Written on iPad; read-only on iPhone and Mac.
//  • Notes      — Markdown notes with [[links]], backlinks, tags, graph, daily notes
//  • Écriture   — Ulysses-style writing projects: ordered sheets, goals, focus mode, export
// The vault can live on the device, in any synced folder, or sync with your own WebDAV server.

@main
struct CarnetsApp: App {
    @State private var vault = VaultStore.shared
    @State private var store = NotebookStore.shared
    @State private var router = AppRouter.shared
    @State private var sync = SyncCenter.shared
    @State private var stats = WritingStats.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(vault)
                .environment(store)
                .environment(router)
                .environment(sync)
                .environment(stats)
                .task {
                    HandwritingIndexer.shared.refreshStalePages()
                    NotebookVaultBridge.shared.exportAll()
                }
        }
        .commands {
            CommandMenu("Espaces") {
                ForEach(AppSpace.allCases) { space in
                    Button(space.title) { router.show(space) }
                        .keyboardShortcut(space.shortcut, modifiers: .command)
                }
                Divider()
                // Works even when the sidebar (and its ⌘ button) is hidden.
                Button("Ouvrir rapidement…") { router.showQuickSwitcher = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                vault.rescan()
                if sync.autoSync { Task { await sync.syncNow() } }
            default:
                store.flushAll()
                vault.waitForWrites()
            }
        }
    }
}
