import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

// MARK: - Library sections

enum LibrarySection: Hashable {
    case all, favorites, recents
    case folder(UUID)
}

struct OpenNotebookRequest: Identifiable {
    let id: UUID
}

// MARK: - LibraryView

struct LibraryView: View {
    @Environment(NotebookStore.self) private var store
    @Bindable private var settings = CarnetsSettings.shared

    @State private var section: LibrarySection? = .all
    @State private var searchText = ""
    @State private var openRequest: OpenNotebookRequest?

    @State private var showNewNotebook = false
    @State private var showPDFImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false
    @State private var showSettings = false

    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: Folder?
    @State private var pendingDelete: Notebook?

    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var sharedFile: SharedFile?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            NavigationStack {
                detail
            }
        }
        .fullScreenCover(item: $openRequest) { request in
            NotebookEditorView(notebookID: request.id) {
                openRequest = nil
            }
        }
        .sheet(isPresented: $showNewNotebook) {
            NewNotebookSheet(folderID: currentFolderID) { notebook in
                openNotebook(notebook.id)
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsSheet()
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(items: [file.url])
                .ignoresSafeArea()
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { importPDFs(urls) }
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItems,
                      maxSelectionCount: 100, matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            photoItems = []
            importPhotos(items)
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                importScans(images)
            } onCancel: {
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .alert("Renommer", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Titre", text: $renameText)
            Button("Renommer") {
                if let notebook = renaming { store.rename(notebook.id, to: renameText) }
                renaming = nil
            }
            Button("Annuler", role: .cancel) { renaming = nil }
        }
        .alert("Nouveau dossier", isPresented: $showNewFolder) {
            TextField("Nom du dossier", text: $folderName)
            Button("Créer") {
                let folder = store.createFolder(named: folderName)
                section = .folder(folder.id)
                folderName = ""
            }
            Button("Annuler", role: .cancel) { folderName = "" }
        }
        .alert("Renommer le dossier", isPresented: Binding(get: { renamingFolder != nil },
                                                           set: { if !$0 { renamingFolder = nil } })) {
            TextField("Nom du dossier", text: $folderName)
            Button("Renommer") {
                if let folder = renamingFolder { store.renameFolder(folder.id, to: folderName) }
                renamingFolder = nil
                folderName = ""
            }
            Button("Annuler", role: .cancel) { renamingFolder = nil; folderName = "" }
        }
        .confirmationDialog("Supprimer « \(pendingDelete?.title ?? "") » ?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Supprimer le carnet", role: .destructive) {
                if let notebook = pendingDelete { store.delete(notebook.id) }
                pendingDelete = nil
            }
        } message: {
            Text("Toutes ses pages seront définitivement supprimées.")
        }
        .alert("Une erreur est survenue", isPresented: Binding(get: { errorMessage != nil },
                                                               set: { if !$0 { errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "")
        }
        .overlay {
            if let busyMessage {
                VStack(spacing: 12) {
                    ProgressView()
                    Text(busyMessage).font(.callout)
                }
                .padding(24)
                .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .onOpenURL { url in
            guard url.isFileURL else { return }
            importPDFs([url], openWhenSingle: true)
        }
    }

    // MARK: Sidebar

    private var sidebar: some View {
        List(selection: $section) {
            Section {
                Label("Tous les carnets", systemImage: "books.vertical")
                    .badge(store.notebooks.count)
                    .tag(LibrarySection.all)
                Label("Favoris", systemImage: "star")
                    .tag(LibrarySection.favorites)
                Label("Récents", systemImage: "clock")
                    .tag(LibrarySection.recents)
            }
            Section("Dossiers") {
                ForEach(store.folders) { folder in
                    Label(folder.name, systemImage: "folder")
                        .badge(store.notebooks(in: folder.id).count)
                        .tag(LibrarySection.folder(folder.id))
                        .contextMenu {
                            Button {
                                folderName = folder.name
                                renamingFolder = folder
                            } label: {
                                Label("Renommer", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                if section == .folder(folder.id) { section = .all }
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
                    showNewFolder = true
                } label: {
                    Label("Nouveau dossier", systemImage: "folder.badge.plus")
                }
            }
        }
        .navigationTitle("Carnets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showSettings = true
                } label: {
                    Label("Réglages", systemImage: "gearshape")
                }
            }
        }
    }

    // MARK: Detail

    private var currentFolderID: UUID? {
        if case .folder(let id) = section { return id }
        return nil
    }

    private var sectionTitle: String {
        switch section ?? .all {
        case .all:               return "Tous les carnets"
        case .favorites:         return "Favoris"
        case .recents:           return "Récents"
        case .folder(let id):    return store.folder(id)?.name ?? "Dossier"
        }
    }

    private var visibleNotebooks: [Notebook] {
        let base: [Notebook]
        switch section ?? .all {
        case .all:            base = store.notebooks
        case .favorites:      base = store.notebooks.filter(\.isFavorite)
        case .recents:
            return Array(store.notebooks
                .filter { $0.openedAt != nil }
                .sorted { ($0.openedAt ?? .distantPast) > ($1.openedAt ?? .distantPast) }
                .prefix(24))
        case .folder(let id): base = store.notebooks(in: id)
        }
        switch settings.librarySort {
        case .modified: return base.sorted { $0.modifiedAt > $1.modifiedAt }
        case .opened:   return base.sorted { ($0.openedAt ?? $0.modifiedAt) > ($1.openedAt ?? $1.modifiedAt) }
        case .created:  return base.sorted { $0.createdAt > $1.createdAt }
        case .title:    return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    @ViewBuilder
    private var detail: some View {
        Group {
            if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
                SearchResultsView(query: searchText) { id, page in
                    openNotebook(id, page: page)
                }
            } else if visibleNotebooks.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 28)],
                              alignment: .leading, spacing: 34) {
                        ForEach(visibleNotebooks) { notebook in
                            NotebookCell(notebook: notebook)
                                .onTapGesture { openNotebook(notebook.id) }
                                .contextMenu { contextMenu(for: notebook) }
                                .draggable(notebook.id.uuidString) {
                                    NotebookCoverView(notebook: notebook).frame(width: 90, height: 120)
                                }
                        }
                    }
                    .padding(28)
                }
                .background(Color(uiColor: .systemGroupedBackground))
            }
        }
        .navigationTitle(sectionTitle)
        .searchable(text: $searchText, prompt: "Titres, écriture, PDF…")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Trier par", selection: $settings.librarySort) {
                        ForEach(LibrarySort.allCases) { Text($0.label).tag($0) }
                    }
                } label: {
                    Label("Trier", systemImage: "arrow.up.arrow.down")
                }
                .onChange(of: settings.librarySort) { settings.save() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                createMenu
            }
        }
    }

    private var createMenu: some View {
        Menu {
            Button {
                showNewNotebook = true
            } label: {
                Label("Nouveau carnet", systemImage: "book.closed")
            }
            Button {
                quickNote()
            } label: {
                Label("Note rapide", systemImage: "square.and.pencil")
            }
            Divider()
            Button {
                showPDFImporter = true
            } label: {
                Label("Importer un PDF…", systemImage: "doc.richtext")
            }
            Button {
                showPhotoPicker = true
            } label: {
                Label("Importer des photos…", systemImage: "photo.on.rectangle")
            }
            if VNDocumentCameraViewController.isSupported {
                Button {
                    showScanner = true
                } label: {
                    Label("Numériser un document", systemImage: "doc.viewfinder")
                }
            }
            Divider()
            Button {
                folderName = ""
                showNewFolder = true
            } label: {
                Label("Nouveau dossier", systemImage: "folder.badge.plus")
            }
        } label: {
            Label("Créer", systemImage: "plus")
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(section == .favorites ? "Aucun favori" : "Aucun carnet", systemImage: "book.closed")
        } description: {
            Text(section == .favorites
                 ? "Touchez longuement un carnet pour l’ajouter aux favoris."
                 : "Créez un carnet pour écrire à la main, ou importez un PDF à annoter.")
        } actions: {
            if section != .favorites && section != .recents {
                Button("Nouveau carnet") { showNewNotebook = true }
                    .buttonStyle(.glassProminent)
                Button("Importer un PDF") { showPDFImporter = true }
                    .buttonStyle(.glass)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for notebook: Notebook) -> some View {
        Button {
            openNotebook(notebook.id)
        } label: {
            Label("Ouvrir", systemImage: "book")
        }
        Button {
            renameText = notebook.title
            renaming = notebook
        } label: {
            Label("Renommer", systemImage: "pencil")
        }
        Button {
            store.toggleFavorite(notebook.id)
        } label: {
            Label(notebook.isFavorite ? "Retirer des favoris" : "Ajouter aux favoris",
                  systemImage: notebook.isFavorite ? "star.slash" : "star")
        }
        Menu {
            Button("Aucun dossier") { store.move(notebook.id, to: nil) }
            ForEach(store.folders) { folder in
                Button(folder.name) { store.move(notebook.id, to: folder.id) }
            }
        } label: {
            Label("Déplacer vers", systemImage: "folder")
        }
        Menu {
            Button("Aperçu de la première page") { store.setCover(notebook.id, nil) }
            ForEach(CoverStyle.allCases) { cover in
                Button(cover.label) { store.setCover(notebook.id, cover) }
            }
        } label: {
            Label("Couverture", systemImage: "paintpalette")
        }
        Button {
            store.duplicate(notebook.id)
        } label: {
            Label("Dupliquer", systemImage: "plus.square.on.square")
        }
        Button {
            exportPDF(notebook)
        } label: {
            Label("Exporter en PDF", systemImage: "square.and.arrow.up")
        }
        Divider()
        Button(role: .destructive) {
            pendingDelete = notebook
        } label: {
            Label("Supprimer", systemImage: "trash")
        }
    }

    // MARK: Actions

    private func openNotebook(_ id: UUID, page: Int? = nil) {
        if let page {
            store.update(id, touch: false) { $0.lastPageIndex = page }
        }
        store.markOpened(id)
        openRequest = OpenNotebookRequest(id: id)
    }

    private func quickNote() {
        let title = "Note du " + Date.now.formatted(date: .abbreviated, time: .shortened)
        let notebook = store.createNotebook(title: title, cover: nil, template: settings.defaultTemplate,
                                            paper: settings.defaultPaper, format: settings.defaultFormat,
                                            landscape: false, folderID: currentFolderID)
        openNotebook(notebook.id)
    }

    private func importPDFs(_ urls: [URL], openWhenSingle: Bool = true) {
        guard !urls.isEmpty else { return }
        busyMessage = urls.count == 1 ? "Importation du PDF…" : "Importation de \(urls.count) PDF…"
        let folder = currentFolderID
        Task {
            var imported: [Notebook] = []
            for url in urls {
                do {
                    imported.append(try await store.importPDF(from: url, folderID: folder))
                } catch {
                    errorMessage = "« \(url.lastPathComponent) » : \(error.localizedDescription)"
                }
            }
            busyMessage = nil
            if openWhenSingle, imported.count == 1, let first = imported.first {
                openNotebook(first.id)
            }
        }
    }

    private func importPhotos(_ items: [PhotosPickerItem]) {
        busyMessage = "Importation des photos…"
        let folder = currentFolderID
        Task {
            var images: [UIImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    images.append(image)
                }
            }
            do {
                let title = "Photos du " + Date.now.formatted(date: .abbreviated, time: .omitted)
                let notebook = try await store.importImages(images, title: title, folderID: folder)
                busyMessage = nil
                openNotebook(notebook.id)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importScans(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        busyMessage = "Création du carnet…"
        let folder = currentFolderID
        Task {
            do {
                let title = "Numérisation du " + Date.now.formatted(date: .abbreviated, time: .shortened)
                let notebook = try await store.importImages(images, title: title, folderID: folder)
                busyMessage = nil
                openNotebook(notebook.id)
            } catch {
                busyMessage = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    private func exportPDF(_ notebook: Notebook) {
        store.flush(notebook.id)
        store.waitForPendingWrites()
        guard let latest = store.notebook(notebook.id) else { return }
        let files = store.files(for: notebook.id)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(PageRenderer.exportFileName(latest.title, ext: "pdf"))
        busyMessage = "Exportation du PDF…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: url)
                    try PageRenderer.exportPDF(notebook: latest, files: files, drawings: nil, to: url)
                }.value
                sharedFile = SharedFile(url: url)
            } catch {
                errorMessage = error.localizedDescription
            }
            busyMessage = nil
        }
    }
}
