import SwiftUI
import Observation

// MARK: - Sections & routes

enum AppSection: Hashable {
    case notes
    case folder(String)
    case graph
    case tags
    case search
    case writing
    case project(String)
    case library(LibrarySection)

    var isLibrary: Bool {
        if case .library = self { return true }
        return false
    }
}

enum NotesRoute: Hashable {
    case note(String)
    case folder(String)
    case tag(String)
    case project(String)
}

// MARK: - AppRouter

@Observable final class AppRouter {
    static let shared = AppRouter()

    private(set) var section: AppSection? = .notes
    var path: [NotesRoute] = []
    /// Set through `openNotebook(_:)` / `closeNotebook()` so sync knows when a notebook is open.
    var openNotebookRequest: OpenNotebookRequest?
    var showQuickSwitcher = false
    var showSettings = false

    private init() {}

    /// Sidebar selection: switching section starts a fresh navigation stack.
    func select(_ newSection: AppSection?) {
        guard newSection != section else { return }
        section = newSection
        path = []
    }

    /// Opens a note from anywhere; notebook companion notes open the handwriting editor.
    func openNote(_ notePath: String) {
        let vault = VaultStore.shared
        if let id = vault.note(notePath)?.notebookID {
            openNotebook(id)
            return
        }
        if section == nil || section?.isLibrary == true {
            section = .notes
            path = [.note(notePath)]
        } else {
            path.append(.note(notePath))
        }
    }

    func push(_ route: NotesRoute) {
        if case .note(let notePath) = route, let id = VaultStore.shared.note(notePath)?.notebookID {
            openNotebook(id)
            return
        }
        path.append(route)
    }

    func openToday() {
        let today = VaultStore.shared.dailyNote()
        section = .folder(VaultPaths.journal)
        path = [.note(today)]
    }

    func openNotebook(_ id: UUID, page: Int? = nil) {
        let store = NotebookStore.shared
        guard store.notebook(id) != nil else { return }
        if let page { store.update(id, touch: false) { $0.lastPageIndex = page } }
        store.markOpened(id)
        SyncCenter.shared.isNotebookOpen = true
        openNotebookRequest = OpenNotebookRequest(id: id)
    }

    func closeNotebook() {
        openNotebookRequest = nil
        SyncCenter.shared.isNotebookOpen = false
        SyncCenter.shared.localChangeOccurred()
    }

    /// carnets://carnet/<uuid> and carnets://note?path=<vault path>
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "carnets" else { return false }
        if url.host == "carnet", let id = UUID(uuidString: url.lastPathComponent) {
            openNotebook(id)
            return true
        }
        if url.host == "note",
           let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
           let notePath = items.first(where: { $0.name == "path" })?.value {
            openNote(notePath)
            return true
        }
        return false
    }
}
