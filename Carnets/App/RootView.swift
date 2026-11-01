import SwiftUI

// MARK: - RootView
// Three apps in one window, one tab each, all stored in the same vault:
//  • Carnets  — handwritten notebooks (written on iPad, readable on iPhone and Mac)
//  • Notes    — the Obsidian-style vault
//  • Écriture — Ulysses-style writing projects

struct RootView: View {
    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var importError: String?

    var body: some View {
        @Bindable var router = router
        TabView(selection: Binding(get: { router.space }, set: { router.show($0) })) {
            Tab(AppSpace.carnets.title, systemImage: AppSpace.carnets.symbol, value: AppSpace.carnets) {
                CarnetsSpaceView()
            }
            Tab(AppSpace.notes.title, systemImage: AppSpace.notes.symbol, value: AppSpace.notes) {
                NotesSpaceView()
            }
            Tab(AppSpace.writing.title, systemImage: AppSpace.writing.symbol, value: AppSpace.writing) {
                WritingSpaceView()
            }
        }
        .tabViewStyle(.tabBarOnly)
        .fullScreenCover(item: $router.openNotebookRequest, onDismiss: {
            SyncCenter.shared.isNotebookOpen = false
        }) { request in
            NotebookEditorView(notebookID: request.id) {
                router.closeNotebook()
            }
        }
        .sheet(isPresented: $router.showQuickSwitcher) {
            QuickSwitcher()
        }
        .sheet(isPresented: $router.showSettings) {
            SettingsSheet()
        }
        .sheet(isPresented: $router.showGoodNotesImport) {
            GoodNotesImportSheet()
        }
        .onOpenURL { url in
            if router.handle(url) { return }
            guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
            guard !store.isReadOnly else {
                importError = "Importez les PDF sur iPad : sur \(Platform.deviceName), les carnets sont en lecture seule."
                return
            }
            Task {
                do {
                    let notebook = try await store.importPDF(from: url, folderID: nil)
                    if notebook.origin == .goodNotes { ImportedTextRecognizer.shared.enqueueAllPages(of: notebook.id) }
                    router.openNotebook(notebook.id)
                } catch {
                    importError = error.localizedDescription
                }
            }
        }
        .alert("Import impossible", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError ?? "")
        }
    }
}

// MARK: - The three spaces

struct CarnetsSpaceView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        // On iPhone, open on the content rather than on the sidebar.
        NavigationSplitView(preferredCompactColumn: $router.carnetsColumn) {
            CarnetsSidebar()
        } detail: {
            NavigationStack {
                NotebookLibraryView(section: router.librarySection ?? .all)
            }
            .id(router.librarySection)
        }
    }
}

struct NotesSpaceView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(preferredCompactColumn: $router.notesColumn) {
            NotesSidebar()
        } detail: {
            NotesStack(path: $router.notesPath) {
                switch router.notesSection ?? .all {
                case .all:                NotesBrowserView(folder: nil)
                case .folder(let folder): NotesBrowserView(folder: folder)
                case .graph:              GraphView()
                case .tags:               TagsView()
                case .search:             UnifiedSearchView()
                }
            }
            .id(router.notesSection)
        }
    }
}

struct WritingSpaceView: View {
    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(preferredCompactColumn: $router.writingColumn) {
            WritingSidebar()
        } detail: {
            NotesStack(path: $router.writingPath) {
                switch router.writingSection ?? .projects {
                case .projects:            ProjectsView()
                case .project(let folder): ProjectView(folder: folder)
                }
            }
            .id(router.writingSection)
        }
    }
}

// MARK: - NotesStack (navigation for notes, folders, tags and writing projects)

struct NotesStack<Root: View>: View {
    @Environment(AppRouter.self) private var router
    @Binding private var path: [NotesRoute]
    private let root: Root

    init(path: Binding<[NotesRoute]>, @ViewBuilder root: () -> Root) {
        _path = path
        self.root = root()
    }

    var body: some View {
        NavigationStack(path: $path) {
            root.navigationDestination(for: NotesRoute.self) { route in
                destination(route)
            }
        }
    }

    @ViewBuilder
    private func destination(_ route: NotesRoute) -> some View {
        switch route {
        case .note(let path):
            NoteEditorView(path: path) { next in router.push(.note(next)) }
                .id(path)
        case .companion(let path):
            NoteEditorView(path: path) { next in router.push(.note(next)) }
                .id("companion-" + path)
        case .folder(let folder):
            NotesBrowserView(folder: folder)
        case .tag(let tag):
            TaggedNotesView(tag: tag)
        case .project(let folder):
            ProjectView(folder: folder)
        }
    }
}

// MARK: - Shared sidebar chrome (quick switcher, settings, sync status)

struct SidebarChrome: ViewModifier {
    @Environment(AppRouter.self) private var router
    let title: String

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        router.showQuickSwitcher = true
                    } label: {
                        Label("Ouvrir rapidement", systemImage: "command")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        router.showSettings = true
                    } label: {
                        Label("Réglages", systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SyncStatusFooter()
            }
    }
}

extension View {
    func sidebarChrome(_ title: String) -> some View {
        modifier(SidebarChrome(title: title))
    }
}

// MARK: - Sync status (bottom of the sidebar)

struct SyncStatusFooter: View {
    @Environment(SyncCenter.self) private var sync
    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(sync.lastError != nil ? Color.orange : Color.secondary)
                .symbolEffect(.pulse, isActive: sync.isSyncing)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.footnote.weight(.medium))
                Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if sync.isConfigured {
                Button {
                    Task { await sync.syncNow() }
                } label: {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                .disabled(sync.isSyncing)
                .accessibilityLabel("Synchroniser maintenant")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
        .contentShape(Rectangle())
        .onTapGesture { if !sync.isConfigured { router.showSettings = true } }
    }

    private var icon: String {
        if !sync.isConfigured { return vault.isExternal ? "folder" : "internaldrive" }
        if sync.lastError != nil { return "exclamationmark.icloud" }
        return sync.isSyncing ? "arrow.triangle.2.circlepath.icloud" : "checkmark.icloud"
    }

    private var title: String {
        if !sync.isConfigured { return vault.isExternal ? "Coffre : \(vault.rootURL.lastPathComponent)" : "Coffre local" }
        if sync.isSyncing { return "Synchronisation…" }
        if sync.lastError != nil { return "Synchronisation impossible" }
        return "Serveur synchronisé"
    }

    private var subtitle: String {
        if !sync.isConfigured { return "Touchez pour connecter votre serveur" }
        if let error = sync.lastError { return error }
        if let date = sync.lastSync {
            return (sync.lastMessage.map { $0 + " · " } ?? "") + date.formatted(.relative(presentation: .named))
        }
        return "Jamais synchronisé"
    }
}

// MARK: - Quick switcher (⌘O)

struct QuickSwitcher: View {
    @Environment(VaultStore.self) private var vault
    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var notes: [VaultNote] { vault.linkSuggestions(for: query, limit: 30) }

    private var notebooks: [Notebook] {
        let q = LibrarySearch.normalized(query)
        let all = store.notebooks.sorted { $0.modifiedAt > $1.modifiedAt }
        return Array((q.isEmpty ? all : all.filter { LibrarySearch.normalized($0.title).contains(q) }).prefix(12))
    }

    var body: some View {
        NavigationStack {
            List {
                let trimmed = query.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && !notes.contains(where: { $0.title.lowercased() == trimmed.lowercased() }) {
                    Button {
                        let path = vault.createNote(in: "", title: trimmed, body: "# \(VaultPaths.sanitizedName(trimmed))\n\n")
                        dismiss()
                        router.openNote(path)
                    } label: {
                        Label("Créer la note « \(trimmed) »", systemImage: "square.and.pencil")
                    }
                }
                if !notes.isEmpty {
                    Section("Notes") {
                        ForEach(notes) { note in
                            Button {
                                dismiss()
                                router.openNote(note.path)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(note.title).font(.body.weight(.medium))
                                    Text(note.folder.isEmpty ? "Coffre" : note.folder).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !notebooks.isEmpty {
                    Section("Carnets manuscrits") {
                        ForEach(notebooks) { notebook in
                            Button {
                                dismiss()
                                router.openNotebook(notebook.id)
                            } label: {
                                Label(notebook.title, systemImage: "pencil.and.scribble")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Aller à une note ou un carnet…")
            .navigationTitle("Ouvrir")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
    }
}
