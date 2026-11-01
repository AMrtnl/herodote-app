import SwiftUI

// MARK: - Carnets sidebar (handwritten notebooks)

struct CarnetsSidebar: View {
    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router

    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: Folder?

    private var importedCount: Int { store.notebooks.filter { $0.origin == .goodNotes }.count }
    private var documentCount: Int {
        store.notebooks.filter { LibrarySection.documentOrigins.contains($0.origin) }.count
    }

    var body: some View {
        List(selection: Binding(get: { router.librarySection }, set: { router.selectLibrary($0) })) {
            if store.isReadOnly {
                Section {
                    ReadOnlyBanner()
                        .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
                }
            }

            Section("Bibliothèque") {
                Label("Tous les carnets", systemImage: "books.vertical")
                    .badge(store.notebooks.count)
                    .tag(LibrarySection.all)
                Label("Favoris", systemImage: "star")
                    .tag(LibrarySection.favorites)
                Label("Récents", systemImage: "clock")
                    .tag(LibrarySection.recents)
                if documentCount > 0 {
                    Label("PDF et documents", systemImage: "doc.richtext")
                        .badge(documentCount)
                        .tag(LibrarySection.documents)
                }
                if importedCount > 0 {
                    Label("Importés de GoodNotes", systemImage: "square.and.arrow.down.on.square")
                        .badge(importedCount)
                        .tag(LibrarySection.imported)
                }
            }

            Section("Dossiers") {
                ForEach(store.folders) { folder in
                    folderRow(folder)
                }
                if store.folders.isEmpty {
                    Text(store.isReadOnly ? "Aucun dossier" : "Rangez vos carnets dans des dossiers")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !store.isReadOnly {
                    Button {
                        folderName = ""
                        showNewFolder = true
                    } label: {
                        Label("Nouveau dossier", systemImage: "folder.badge.plus")
                    }
                }
            }

            if !store.isReadOnly {
                Section("Importer") {
                    Button {
                        router.showGoodNotesImport = true
                    } label: {
                        Label("Depuis GoodNotes…", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
        .sidebarChrome("Carnets")
        .alert("Nouveau dossier de carnets", isPresented: $showNewFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let folder = store.createFolder(named: folderName)
                router.selectLibrary(.folder(folder.id))
            }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Renommer le dossier", isPresented: Binding(get: { renamingFolder != nil },
                                                           set: { if !$0 { renamingFolder = nil } })) {
            TextField("Nom du dossier", text: $folderName)
            Button("Renommer") {
                if let folder = renamingFolder { store.renameFolder(folder.id, to: folderName) }
                renamingFolder = nil
            }
            Button("Annuler", role: .cancel) { renamingFolder = nil }
        }
    }

    @ViewBuilder
    private func folderRow(_ folder: Folder) -> some View {
        let row = Label(folder.name, systemImage: "folder")
            .badge(store.notebooks(in: folder.id).count)
            .tag(LibrarySection.folder(folder.id))
        if store.isReadOnly {
            row
        } else {
            row
                .contextMenu {
                    Button {
                        folderName = folder.name
                        renamingFolder = folder
                    } label: {
                        Label("Renommer", systemImage: "pencil")
                    }
                    Button(role: .destructive) {
                        if router.librarySection == .folder(folder.id) { router.selectLibrary(.all) }
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
    }
}

// MARK: - Read-only banner (iPhone, Mac)

struct ReadOnlyBanner: View {
    var compact = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .font(.body.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(Platform.readOnlyTitle)
                    .font(.subheadline.weight(.semibold))
                if !compact {
                    Text(Platform.readOnlyExplanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Notes sidebar (the vault)

struct NotesSidebar: View {
    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router

    @State private var showNewFolder = false
    @State private var folderName = ""

    /// Top-level vault folders (Carnets and Écriture have their own spaces).
    private var topFolders: [String] {
        vault.subfolders(of: "").filter {
            $0 != VaultPaths.carnets && $0 != VaultPaths.writing && $0 != VaultPaths.attachments
        }
    }

    var body: some View {
        List(selection: Binding(get: { router.notesSection }, set: { router.selectNotes($0) })) {
            Section("Coffre") {
                Label("Toutes les notes", systemImage: "doc.text")
                    .badge(vault.notes.count)
                    .tag(NotesSection.all)
                Button {
                    router.openToday()
                } label: {
                    Label("Aujourd’hui", systemImage: "calendar")
                }
                Label("Graphe", systemImage: "point.3.connected.trianglepath.dotted")
                    .tag(NotesSection.graph)
                Label("Étiquettes", systemImage: "number")
                    .tag(NotesSection.tags)
                Label("Recherche", systemImage: "magnifyingglass")
                    .tag(NotesSection.search)
            }
            Section("Dossiers") {
                ForEach(topFolders, id: \.self) { folder in
                    Label(VaultPaths.fileName(of: folder),
                          systemImage: folder == VaultPaths.journal ? "calendar.badge.clock" : "folder")
                        .badge(vault.notes(inFolder: folder).count)
                        .tag(NotesSection.folder(folder))
                }
                Label("Notes des carnets", systemImage: "pencil.and.scribble")
                    .badge(vault.notes(inFolder: VaultPaths.carnets).count)
                    .tag(NotesSection.folder(VaultPaths.carnets))
                Button {
                    folderName = ""
                    showNewFolder = true
                } label: {
                    Label("Nouveau dossier", systemImage: "folder.badge.plus")
                }
            }
        }
        .sidebarChrome("Notes")
        .alert("Nouveau dossier", isPresented: $showNewFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let folder = vault.createFolder(in: "", name: folderName.isEmpty ? "Nouveau dossier" : folderName)
                router.selectNotes(.folder(folder))
            }
            Button("Annuler", role: .cancel) {}
        }
    }
}

// MARK: - Écriture sidebar (writing projects)

struct WritingSidebar: View {
    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router

    @State private var showNewProject = false
    @State private var projectName = ""

    var body: some View {
        List(selection: Binding(get: { router.writingSection }, set: { router.selectWriting($0) })) {
            Section {
                Label("Tous les projets", systemImage: "text.book.closed")
                    .badge(vault.projectFolders.count)
                    .tag(WritingSection.projects)
            }
            Section("Projets") {
                ForEach(vault.projectFolders, id: \.self) { folder in
                    Label(vault.project(at: folder)?.title ?? VaultPaths.fileName(of: folder), systemImage: "doc.richtext")
                        .tag(WritingSection.project(folder))
                }
                Button {
                    projectName = ""
                    showNewProject = true
                } label: {
                    Label("Nouveau projet", systemImage: "plus")
                }
            }
        }
        .sidebarChrome("Écriture")
        .alert("Nouveau projet d’écriture", isPresented: $showNewProject) {
            TextField("Titre du projet", text: $projectName)
            Button("Créer") {
                let folder = vault.createProject(title: projectName.isEmpty ? "Projet sans titre" : projectName)
                router.openProject(folder)
            }
            Button("Annuler", role: .cancel) {}
        }
    }
}
