import SwiftUI

// MARK: - Carnets
// Handwritten notebooks for iPad & iPhone: paper templates, PDF annotation,
// Apple Pencil tools, shape snapping, on-device handwriting search and conversion.

@main
struct CarnetsApp: App {
    @State private var store = NotebookStore.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .task {
                    HandwritingIndexer.shared.refreshStalePages()
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active {
                store.flushAll()
            }
        }
    }
}
