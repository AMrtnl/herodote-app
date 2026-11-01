import SwiftUI

// MARK: - RootView
// One window, three ways of writing: Notes (Obsidian-style vault), Écriture (Ulysses-style
// projects) and Carnets manuscrits (GoodNotes-style handwriting) — all stored in the same vault.

struct RootView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var importError: String?

    var body: some View {
        @Bindable var router = router
        NavigationSplitView {
            RootSidebar()
        } detail: {
            detail
                .id(router.section)
        }
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
        .onOpenURL { url in
            if router.handle(url) { return }
            guard url.isFileURL, url.pathExtension.lowercased() == "pdf" else { return }
            Task {
                do {
                    let notebook = try await store.importPDF(from: url, folderID: nil)
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

    @ViewBuilder
    private var detail: some View {
        switch router.section ?? .notes {
        case .notes:
            NotesStack { NotesBrowserView(folder: nil) }
        case .folder(let folder):
            NotesStack { NotesBrowserView(folder: folder) }
        case .graph:
            NotesStack { GraphView() }
        case .tags:
            NotesStack { TagsView() }
        case .search:
            NotesStack { UnifiedSearchView() }
        case .writing:
            NotesStack { ProjectsView() }
        case .project(let folder):
            NotesStack { ProjectView(folder: folder) }
        case .library(let section):
            NavigationStack { NotebookLibraryView(section: section) }
        }
    }
}

// MARK: - NotesStack (shared navigation for notes, folders, tags and writing projects)

struct NotesStack<Root: View>: View {
    @Environment(AppRouter.self) private var router
    private let root: Root

    init(@ViewBuilder root: () -> Root) {
        self.root = root()
    }

    var body: some View {
        @Bindable var router = router
        NavigationStack(path: $router.path) {
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

// MARK: - Sidebar

struct RootSidebar: View {
    @Environment(VaultStore.self) private var vault
    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router

    @State private var showNewProject = false
    @State private var projectName = ""
    @State private var showNewNotebookFolder = false
    @State private var showNewVaultFolder = false
    @State private var folderName = ""
    @State private var renamingNotebookFolder: Folder?

    /// Top-level vault folders shown in the sidebar (system folders have their own sections).
    private var topFolders: [String] {
        vault.subfolders(of: "").filter {
            $0 != VaultPaths.carnets && $0 != VaultPaths.writing && $0 != VaultPaths.attachments
        }
    }

    var body: some View {
        List(selection: Binding(get: { router.section }, set: { router.select($0) })) {
            Section("Coffre") {
                Label("Toutes les notes", systemImage: "doc.text")
                    .badge(vault.notes.count)
                    .tag(AppSection.notes)
                Button {
                    router.openToday()
                } label: {
                    Label("Aujourd’hui", systemImage: "calendar")
                }
                Label("Graphe", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(AppSection.graph)
                Label("Étiquettes", systemImage: "number")
                    .tag(AppSection.tags)
                Label("Recherche", systemImage: "magnifyingglass")
                    .tag(AppSection.search)
                ForEach(topFolders, id: \.self) { folder in
                    Label(VaultPaths.fileName(of: folder),
                          systemImage: folder == VaultPaths.journal ? "calendar.badge.clock" : "folder")
                        .badge(vault.notes(inFolder: folder).count)
                        .tag(AppSection.folder(folder))
                }
                Button {
                    folderName = ""
                    showNewVaultFolder = true
                } label: {
                    Label("Nouveau dossier", systemImage: "folder.badge.plus")
                }
            }

            Section("Écriture") {
                Label("Projets", systemImage: "text.book.closed")
                    .tag(AppSection.writing)
                ForEach(vault.projectFolders, id: \.self) { folder in
                    Label(vault.project(at: folder)?.title ?? VaultPaths.fileName(of: folder), systemImage: "doc.richtext")
                        .tag(AppSection.project(folder))
                }
                Button {
                    projectName = ""
                    showNewProject = true
                } label: {
                    Label("Nouveau projet", systemImage: "plus")
                }
            }

            Section("Carnets manuscrits") {
                Label("Tous les carnets", systemImage: "books.vertical")
                    .badge(store.notebooks.count)
                    .tag(AppSection.library(.all))
                Label("Favoris", systemImage: "star")
                    .tag(AppSection.library(.favorites))
                Label("Récents", systemImage: "clock")
                    .tag(AppSection.library(.recents))
                ForEach(store.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(store.notebooks(in: folder.id).count)
                        .tag(AppSection.library(.folder(folder.id)))
                        .contextMenu {
                            Button {
                                folderName = folder.name
                                renamingNotebookFolder = folder
                            } label: {
                                Label("Renommer", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                if router.section == .library(.folder(folder.id)) { router.select(.library(.all)) }
                                store.deleteFolder(folder.id)
                            } label: {
                                Label("Supprimer le dossier", systemImage: "trash")
                            }
                        }
                        .dropDestination(for: String.self) { identifiers, _ in
                            let ids = identifiers.compactMap(UUID.init(uuidString:))
                            ids.forEach { store.move($0, to: folder.id) }
                            return !ids.isEmpty
                        }
                }
                Button {
                    folderName = ""
                    showNewNotebookFolder = true
                } label: {
                    Label("Nouveau dossier de carnets", systemImage: "folder.badge.plus")
                }
            }
        }
        .navigationTitle("Carnets")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    router.showQuickSwitcher = true
                } label: {
                    Label("Ouvrir rapidement", systemImage: "command")
                }
                .keyboardShortcut("o", modifiers: .command)
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
        .alert("Nouveau projet d’écriture", isPresented: $showNewProject) {
            TextField("Titre du projet", text: $projectName)
            Button("Créer") {
                let folder = vault.createProject(title: projectName.isEmpty ? "Projet sans titre" : projectName)
                router.select(.project(folder))
            }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Nouveau dossier", isPresented: $showNewVaultFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let folder = vault.createFolder(in: "", name: folderName.isEmpty ? "Nouveau dossier" : folderName)
                router.select(.folder(folder))
            }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Nouveau dossier de carnets", isPresented: $showNewNotebookFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let folder = store.createFolder(named: folderName)
                router.select(.library(.folder(folder.id)))
            }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Renommer le dossier", isPresented: Binding(get: { renamingNotebookFolder != nil },
                                                           set: { if !$0 { renamingNotebookFolder = nil } })) {
            TextField("Nom du dossier", text: $folderName)
            Button("Renommer") {
                if let folder = renamingNotebookFolder { store.renameFolder(folder.id, to: folderName) }
                renamingNotebookFolder = nil
            }
            Button("Annuler", role: .cancel) { renamingNotebookFolder = nil }
        }
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
