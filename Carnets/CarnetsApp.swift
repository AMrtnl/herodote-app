import SwiftUI

// MARK: - Carnets
// Three ways of writing in one app, stored in one Obsidian-compatible vault:
//  • Notes      — Markdown notes with [[links]], backlinks, tags, graph, daily notes
//  • Écriture   — Ulysses-style writing projects: ordered sheets, goals, focus mode, export
//  • Carnets    — GoodNotes-style handwriting: Apple Pencil, paper templates, PDF annotation,
//                 shape snapping, on-device handwriting recognition
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
