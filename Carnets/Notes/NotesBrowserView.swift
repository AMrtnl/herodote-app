import SwiftUI
import UIKit

// MARK: - NotesBrowserView (a vault folder, or every note when `folder` is nil)

struct NotesBrowserView: View {
    let folder: String?

    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router
    @AppStorage("notes.sortByTitle") private var sortByTitle = false
    @State private var search = ""
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renaming: VaultNote?
    @State private var renameText = ""
    @State private var renamingFolder: String?

    private var subfolders: [String] {
        guard let folder else { return [] }
        return vault.subfolders(of: folder)
    }

    private var notes: [VaultNote] {
        let base = folder.map { vault.notes(inFolder: $0) } ?? vault.notes
        return base.sorted {
            sortByTitle ? $0.title.localizedStandardCompare($1.title) == .orderedAscending : $0.modified > $1.modified
        }
    }

    private var hits: [VaultStore.NoteHit] {
        let all = vault.search(search)
        guard let folder, !folder.isEmpty else { return all }
        return all.filter { $0.path.hasPrefix(folder + "/") }
    }

    var body: some View {
        List {
            if search.isEmpty {
                if !subfolders.isEmpty {
                    Section("Dossiers") {
                        ForEach(subfolders, id: \.self) { sub in
                            NavigationLink(value: NotesRoute.folder(sub)) {
                                Label {
                                    HStack {
                                        Text(VaultPaths.fileName(of: sub))
                                        Spacer()
                                        Text("\(vault.notes(inFolder: sub).count)").foregroundStyle(.secondary).font(.callout)
                                    }
                                } icon: {
                                    Image(systemName: vault.project(at: sub) != nil ? "doc.richtext" : "folder")
                                }
                            }
                            .contextMenu { folderMenu(sub) }
                        }
                    }
                }
                Section {
                    ForEach(notes) { note in
                        Button {
                            router.push(.note(note.path))
                        } label: {
                            NoteRow(note: note, showFolder: folder == nil)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { noteMenu(note) }
                        .swipeActions {
                            Button(role: .destructive) { vault.trash(note.path) } label: {
                                Label("Corbeille", systemImage: "trash")
                            }
                        }
                    }
                }
            } else {
                ForEach(hits) { hit in
                    Button {
                        router.push(.note(hit.path))
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hit.title).font(.body.weight(.semibold))
                            Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if search.isEmpty && notes.isEmpty && subfolders.isEmpty {
                ContentUnavailableView {
                    Label("Aucune note", systemImage: "doc.text")
                } description: {
                    Text("Les notes sont de simples fichiers Markdown : ouvrez le même coffre dans Obsidian ou sur votre serveur.")
                } actions: {
                    Button("Nouvelle note") { newNote() }
                        .buttonStyle(.glassProminent)
                }
            } else if !search.isEmpty && hits.isEmpty {
                ContentUnavailableView.search(text: search)
            }
        }
        .searchable(text: $search, prompt: "Rechercher dans les notes")
        .navigationTitle(folder.map { $0.isEmpty ? "Coffre" : VaultPaths.fileName(of: $0) } ?? "Toutes les notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Trier", selection: $sortByTitle) {
                        Label("Date de modification", systemImage: "clock").tag(false)
                        Label("Titre", systemImage: "textformat").tag(true)
                    }
                    Divider()
                    Button {
                        folderName = ""
                        showNewFolder = true
                    } label: {
                        Label("Nouveau dossier", systemImage: "folder.badge.plus")
                    }
                    if let folder, !folder.isEmpty, vault.project(at: folder) == nil {
                        Button {
                            vault.makeProject(from: folder)
                            router.select(.project(folder))
                        } label: {
                            Label("Convertir en projet d’écriture", systemImage: "doc.richtext")
                        }
                    }
                } label: {
                    Label("Options", systemImage: "ellipsis")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newNote()
                } label: {
                    Label("Nouvelle note", systemImage: "square.and.pencil")
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .alert("Nouveau dossier", isPresented: $showNewFolder) {
            TextField("Nom", text: $folderName)
            Button("Créer") { _ = vault.createFolder(in: folder ?? "", name: folderName.isEmpty ? "Nouveau dossier" : folderName) }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Renommer la note", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titre", text: $renameText)
            Button("Renommer") {
                if let note = renaming { vault.renameNote(note.path, to: renameText) }
                renaming = nil
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        } message: {
            Text("Les liens vers cette note seront mis à jour dans tout le coffre.")
        }
        .alert("Renommer le dossier", isPresented: Binding(get: { renamingFolder != nil }, set: { if !$0 { renamingFolder = nil } })) {
            TextField("Nom", text: $folderName)
            Button("Renommer") {
                if let folderPath = renamingFolder { _ = vault.renameFolder(folderPath, to: folderName) }
                renamingFolder = nil
            }
            Button("Annuler", role: .cancel) { renamingFolder = nil }
        }
    }

    private func newNote() {
        let path = vault.createNote(in: folder ?? "", title: "Sans titre", body: "")
        router.push(.note(path))
    }

    @ViewBuilder
    private func noteMenu(_ note: VaultNote) -> some View {
        Button {
            renameText = note.title
            renaming = note
        } label: {
            Label("Renommer", systemImage: "pencil")
        }
        Menu {
            Button("Coffre (racine)") { vault.move(note.path, to: VaultPaths.fileName(of: note.path)) }
            ForEach(vault.folders.filter { $0 != note.folder && !$0.hasPrefix(VaultPaths.carnets) }, id: \.self) { target in
                Button(target) { vault.move(note.path, to: VaultPaths.join(target, VaultPaths.fileName(of: note.path))) }
            }
        } label: {
            Label("Déplacer vers", systemImage: "folder")
        }
        Button {
            UIPasteboard.general.string = "[[\(note.title)]]"
        } label: {
            Label("Copier le lien interne", systemImage: "link")
        }
        Divider()
        Button(role: .destructive) {
            vault.trash(note.path)
        } label: {
            Label("Mettre à la corbeille", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func folderMenu(_ path: String) -> some View {
        Button {
            folderName = VaultPaths.fileName(of: path)
            renamingFolder = path
        } label: {
            Label("Renommer", systemImage: "pencil")
        }
        if vault.project(at: path) == nil {
            Button {
                vault.makeProject(from: path)
            } label: {
                Label("Convertir en projet d’écriture", systemImage: "doc.richtext")
            }
        }
        Button(role: .destructive) {
            vault.trash(path)
        } label: {
            Label("Mettre à la corbeille", systemImage: "trash")
        }
    }
}

// MARK: - NoteRow

struct NoteRow: View {
    let note: VaultNote
    var showFolder = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.body)
                .foregroundStyle(tint)
                .frame(width: 22)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                if !note.excerpt.isEmpty {
                    Text(note.excerpt)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 6) {
                    Text(note.modified.formatted(.relative(presentation: .named)))
                    if showFolder && !note.folder.isEmpty {
                        Text("·")
                        Label(note.folder, systemImage: "folder").labelStyle(.titleAndIcon)
                    }
                    ForEach(note.tags.prefix(3), id: \.self) { tag in
                        Text("#\(tag)").foregroundStyle(Color.accentColor)
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private var symbol: String {
        switch note.kind {
        case .note:     return "doc.text"
        case .daily:    return "calendar"
        case .notebook: return "pencil.and.scribble"
        case .sheet:    return "text.page"
        }
    }

    private var tint: Color {
        switch note.kind {
        case .notebook: return .accentColor
        case .daily:    return .blue
        case .sheet:    return .purple
        case .note:     return .secondary
        }
    }
}

// MARK: - Tags

struct TagsView: View {
    @Environment(VaultStore.self) private var vault

    var body: some View {
        List {
            ForEach(vault.allTags) { item in
                NavigationLink(value: NotesRoute.tag(item.tag)) {
                    HStack {
                        Text("#\(item.tag)").foregroundStyle(Color.accentColor)
                        Spacer()
                        Text("\(item.count)").foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if vault.allTags.isEmpty {
                ContentUnavailableView("Aucune étiquette", systemImage: "number",
                                       description: Text("Ajoutez des #étiquettes dans vos notes ou leurs propriétés."))
            }
        }
        .navigationTitle("Étiquettes")
    }
}

struct TaggedNotesView: View {
    let tag: String
    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router

    var body: some View {
        List {
            ForEach(vault.notes.filter { $0.tags.contains(tag) }.sorted { $0.modified > $1.modified }) { note in
                Button {
                    router.push(.note(note.path))
                } label: {
                    NoteRow(note: note, showFolder: true)
                }
                .buttonStyle(.plain)
            }
        }
        .navigationTitle("#\(tag)")
    }
}

// MARK: - Unified search (notes + handwriting)

struct UnifiedSearchView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router
    @State private var query = ""

    var body: some View {
        let noteHits = vault.search(query)
        let inkHits = LibrarySearch.search(query, in: store.notebooks)
        List {
            if !noteHits.isEmpty {
                Section("Notes (\(noteHits.count))") {
                    ForEach(noteHits.prefix(60)) { hit in
                        Button {
                            router.push(.note(hit.path))
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(hit.title).font(.body.weight(.semibold))
                                Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !inkHits.isEmpty {
                Section("Écriture manuscrite et PDF (\(inkHits.count))") {
                    ForEach(inkHits.prefix(60)) { hit in
                        Button {
                            router.openNotebook(hit.notebookID, page: hit.pageIndex)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Image(systemName: "pencil.and.scribble").foregroundStyle(Color.accentColor)
                                    Text(store.notebook(hit.notebookID)?.title ?? "Carnet").font(.body.weight(.semibold))
                                    if let page = hit.pageIndex {
                                        Text("page \(page + 1)").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Text(hit.snippet).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .overlay {
            if query.isEmpty {
                ContentUnavailableView("Rechercher partout", systemImage: "magnifyingglass",
                                       description: Text("Notes, projets d’écriture, écriture manuscrite reconnue et texte des PDF."))
            } else if noteHits.isEmpty && inkHits.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Rechercher")
        .navigationTitle("Recherche")
    }
}
