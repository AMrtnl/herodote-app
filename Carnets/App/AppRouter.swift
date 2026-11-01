import SwiftUI
import Observation

// MARK: - Spaces
// The app is three apps in one, each with its own tab, sidebar and navigation:
//  • Carnets  — handwritten notebooks (GoodNotes-style), edited on iPad, readable everywhere
//  • Notes    — the Obsidian-compatible vault: notes, links, graph, daily notes
//  • Écriture — Ulysses-style writing projects

enum AppSpace: String, Hashable, CaseIterable, Identifiable {
    case carnets, notes, writing

    var id: String { rawValue }

    var title: String {
        switch self {
        case .carnets: return "Carnets"
        case .notes:   return "Notes"
        case .writing: return "Écriture"
        }
    }

    /// ⌘1, ⌘2, ⌘3.
    var shortcut: KeyEquivalent {
        switch self {
        case .carnets: return "1"
        case .notes:   return "2"
        case .writing: return "3"
        }
    }

    var symbol: String {
        switch self {
        case .carnets: return "pencil.and.scribble"
        case .notes:   return "doc.text"
        case .writing: return "text.book.closed"
        }
    }
}

/// Sidebar selection in the Notes space.
enum NotesSection: Hashable {
    case all
    case folder(String)
    case graph
    case tags
    case search
}

/// Sidebar selection in the Écriture space.
enum WritingSection: Hashable {
    case projects
    case project(String)
}

enum NotesRoute: Hashable {
    case note(String)
    /// A notebook's companion note, edited as Markdown instead of opening the notebook.
    case companion(String)
    case folder(String)
    case tag(String)
    case project(String)
}

// MARK: - AppRouter

@Observable final class AppRouter {
    static let shared = AppRouter()

    /// The selected tab. Set through `show(_:)`, which remembers it for the next launch.
    private(set) var space: AppSpace

    // Carnets
    private(set) var librarySection: LibrarySection? = .all
    // Notes
    private(set) var notesSection: NotesSection? = .all
    var notesPath: [NotesRoute] = []
    // Écriture
    private(set) var writingSection: WritingSection? = .projects
    var writingPath: [NotesRoute] = []

    /// Column shown when a space is collapsed (iPhone, narrow windows): opening something
    /// brings its content on screen even if the sidebar was showing.
    var carnetsColumn = NavigationSplitViewColumn.detail
    var notesColumn = NavigationSplitViewColumn.detail
    var writingColumn = NavigationSplitViewColumn.detail

    /// Set through `openNotebook(_:)` / `closeNotebook()` so sync knows when a notebook is open.
    var openNotebookRequest: OpenNotebookRequest?
    var showQuickSwitcher = false
    var showSettings = false
    var showGoodNotesImport = false

    private init() {
        let saved = UserDefaults.standard.string(forKey: "app.space").flatMap(AppSpace.init(rawValue:))
        space = saved ?? .carnets
    }

    // MARK: Spaces and sidebars

    func show(_ newSpace: AppSpace) {
        guard newSpace != space else { return }
        space = newSpace
        UserDefaults.standard.set(newSpace.rawValue, forKey: "app.space")
    }

    func selectLibrary(_ section: LibrarySection?) {
        show(.carnets)
        librarySection = section
        if section != nil { carnetsColumn = .detail }
    }

    /// Sidebar selection: switching section starts a fresh navigation stack.
    func selectNotes(_ section: NotesSection?) {
        show(.notes)
        if section != nil { notesColumn = .detail }
        guard section != notesSection else { return }
        notesSection = section
        notesPath = []
    }

    func selectWriting(_ section: WritingSection?) {
        show(.writing)
        if section != nil { writingColumn = .detail }
        guard section != writingSection else { return }
        writingSection = section
        writingPath = []
    }

    func openProject(_ folder: String) {
        selectWriting(.project(folder))
    }

    // MARK: Notes

    /// Opens a note from anywhere. Notebook companion notes open the handwriting notebook,
    /// unless `followNotebook` is false (to edit the companion note itself).
    /// Sheets of a writing project open in Écriture, everything else in Notes.
    func openNote(_ notePath: String, followNotebook: Bool = true) {
        let vault = VaultStore.shared
        let notebookID = vault.note(notePath)?.notebookID
        if followNotebook, let notebookID {
            openNotebook(notebookID)
            return
        }
        let route: NotesRoute = notebookID != nil ? .companion(notePath) : .note(notePath)
        if notePath.hasPrefix(VaultPaths.writing + "/") {
            // A sheet opens inside its project, so Back leads to the project.
            let folder = (notePath as NSString).deletingLastPathComponent
            let section: WritingSection = vault.project(at: folder) != nil ? .project(folder) : .projects
            if space == .writing && writingSection == section {
                writingPath.append(route)
            } else {
                show(.writing)
                writingSection = section
                writingPath = [route]
            }
            writingColumn = .detail
            return
        }
        if space == .notes && notesColumn == .detail {
            notesPath.append(route)
        } else {
            show(.notes)
            notesPath = [route]
        }
        notesColumn = .detail
    }

    /// Pushes a route in the current space (Notes when coming from Carnets).
    func push(_ route: NotesRoute) {
        if case .note(let notePath) = route, let id = VaultStore.shared.note(notePath)?.notebookID {
            openNotebook(id)
            return
        }
        switch space {
        case .writing:
            writingPath.append(route)
            writingColumn = .detail
        case .notes:
            notesPath.append(route)
            notesColumn = .detail
        case .carnets:
            show(.notes)
            notesPath = [route]
            notesColumn = .detail
        }
    }

    func openToday() {
        let today = VaultStore.shared.dailyNote()
        show(.notes)
        notesSection = .folder(VaultPaths.journal)
        notesPath = [.note(today)]
        notesColumn = .detail
    }

    // MARK: Notebooks

    func openNotebook(_ id: UUID, page: Int? = nil) {
        let store = NotebookStore.shared
        guard store.notebook(id) != nil else { return }
        if let page {
            if store.isReadOnly {
                ReadingPositions.set(page, for: id)
            } else {
                store.update(id, touch: false) { $0.lastPageIndex = page }
            }
        }
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

// MARK: - Reading positions on read-only devices
// Readers never write notebooks, so the page you were on is remembered on the device.

enum ReadingPositions {
    private static func key(_ id: UUID) -> String { "carnets.reading.\(id.uuidString)" }

    static func page(for id: UUID) -> Int? {
        UserDefaults.standard.object(forKey: key(id)) as? Int
    }

    static func set(_ page: Int, for id: UUID) {
        UserDefaults.standard.set(page, forKey: key(id))
    }

    static func markOpened(_ id: UUID) {
        UserDefaults.standard.set(Date.now, forKey: "carnets.opened.\(id.uuidString)")
    }

    static func openedDate(for id: UUID) -> Date? {
        UserDefaults.standard.object(forKey: "carnets.opened.\(id.uuidString)") as? Date
    }
}
