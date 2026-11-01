import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit

// MARK: - Library sections

enum LibrarySection: Hashable {
    case all, favorites, recents, imported
    case folder(UUID)
}

struct OpenNotebookRequest: Identifiable {
    let id: UUID
}

struct SharedFiles: Identifiable {
    let id = UUID()
    let urls: [URL]
}

// MARK: - NotebookLibraryView (handwritten notebooks, shown in the main window's detail column)

struct NotebookLibraryView: View {
    let section: LibrarySection

    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Bindable private var settings = CarnetsSettings.shared

    @State private var searchText = ""

    @State private var showNewNotebook = false
    @State private var showPDFImporter = false
    @State private var showPhotoPicker = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var showScanner = false

    @State private var renaming: Notebook?
    @State private var renameText = ""
    @State private var showNewFolder = false
    @State private var folderName = ""
    @State private var renamingFolder: Folder?
    @State private var pendingDelete: Notebook?

    @State private var busyMessage: String?
    @State private var errorMessage: String?
    @State private var sharedFile: SharedFile?

    // Multi-selection
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var showMergePrompt = false
    @State private var mergeTitle = ""
    @State private var confirmBatchDelete = false
    @State private var sharedFiles: SharedFiles?
    @State private var infoNotebook: OpenNotebookRequest?

    var body: some View {
        detail
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if isSelecting { selectionBar }
        }
        .sheet(item: $infoNotebook) { request in
            NotebookInfoSheet(notebookID: request.id)
        }
        .sheet(item: $sharedFiles) { files in
            ShareSheet(items: files.urls).ignoresSafeArea()
        }
        .alert("Fusionner \(selection.count) carnets", isPresented: $showMergePrompt) {
            TextField("Titre du nouveau carnet", text: $mergeTitle)
            Button("Fusionner") {
                let ids = orderedSelection
                if let merged = store.merge(ids, title: mergeTitle.isEmpty ? "Carnet fusionné" : mergeTitle) {
                    endSelection()
                    openNotebook(merged.id)
                }
            }
            Button("Annuler", role: .cancel) {}
        } message: {
            Text("Les pages sont réunies dans un nouveau carnet, dans l’ordre affiché. Les carnets d’origine sont conservés.")
        }
        .confirmationDialog("Supprimer \(selection.count) carnet\(selection.count > 1 ? "s" : "") ?",
                            isPresented: $confirmBatchDelete, titleVisibility: .visible) {
            Button("Supprimer", role: .destructive) {
                for id in selection { store.delete(id) }
                endSelection()
            }
        } message: {
            Text("Leurs pages seront définitivement supprimées de Carnets (vos fichiers GoodNotes ne sont pas touchés).")
        }
        .sheet(isPresented: $showNewNotebook) {
            NewNotebookSheet(folderID: currentFolderID) { notebook in
                openNotebook(notebook.id)
            }
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
                router.select(.library(.folder(folder.id)))
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
    }

    // MARK: Detail

    private var currentFolderID: UUID? {
        if case .folder(let id) = section { return id }
        return nil
    }

    private var sectionTitle: String {
        switch section {
        case .all:               return "Tous les carnets"
        case .favorites:         return "Favoris"
        case .recents:           return "Récents"
        case .imported:          return "Importés de GoodNotes"
        case .folder(let id):    return store.folder(id)?.name ?? "Dossier"
        }
    }

    private var visibleNotebooks: [Notebook] {
        let base: [Notebook]
        switch section {
        case .all:            base = store.notebooks
        case .favorites:      base = store.notebooks.filter(\.isFavorite)
        case .imported:       base = store.notebooks.filter { $0.origin == .goodNotes }
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
                                .overlay(alignment: .topTrailing) {
                                    if isSelecting { selectionMark(selection.contains(notebook.id)) }
                                }
                                .opacity(isSelecting && !selection.contains(notebook.id) ? 0.7 : 1)
                                .onTapGesture {
                                    if isSelecting { toggleSelection(notebook.id) } else { openNotebook(notebook.id) }
                                }
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
            if isSelecting {
                ToolbarItem(placement: .topBarLeading) {
                    Button(selection.count == visibleNotebooks.count ? "Tout désélectionner" : "Tout sélectionner") {
                        selection = selection.count == visibleNotebooks.count ? [] : Set(visibleNotebooks.map(\.id))
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(isSelecting ? "OK" : "Sélectionner") {
                    if isSelecting { endSelection() } else { isSelecting = true }
                }
                .disabled(visibleNotebooks.isEmpty && !isSelecting)
            }
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
                router.showGoodNotesImport = true
            } label: {
                Label("Importer depuis GoodNotes…", systemImage: "square.and.arrow.down.on.square")
            }
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

    @ViewBuilder
    private var emptyState: some View {
        if section == .imported {
            ContentUnavailableView {
                Label("Aucun carnet importé", systemImage: "square.and.arrow.down.on.square")
            } description: {
                Text("Exportez vos carnets GoodNotes en PDF (un dossier devient une archive ZIP) et importez-les : ils gardent leurs dossiers, et leur écriture devient cherchable.")
            } actions: {
                Button("Importer depuis GoodNotes") { router.showGoodNotesImport = true }
                    .buttonStyle(.glassProminent)
            }
        } else {
            defaultEmptyState
        }
    }

    private var defaultEmptyState: some View {
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
            infoNotebook = OpenNotebookRequest(id: notebook.id)
        } label: {
            Label(notebook.origin == .goodNotes ? "Infos et mise à jour GoodNotes…" : "Infos…", systemImage: "info.circle")
        }
        Button {
            isSelecting = true
            selection = [notebook.id]
        } label: {
            Label("Sélectionner", systemImage: "checkmark.circle")
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

    // MARK: Multi-selection

    private var orderedSelection: [UUID] {
        visibleNotebooks.map(\.id).filter { selection.contains($0) }
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }

    private func endSelection() {
        isSelecting = false
        selection = []
    }

    private func selectionMark(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title2)
            .symbolRenderingMode(.palette)
            .foregroundStyle(selected ? Color.white : Color.secondary, selected ? Color.accentColor : Color.white.opacity(0.8))
            .background(Circle().fill(.ultraThinMaterial).padding(2))
            .padding(6)
    }

    private var selectionBar: some View {
        let count = selection.count
        let allFavorite = !selection.isEmpty && selection.allSatisfy { store.notebook($0)?.isFavorite == true }
        return HStack(spacing: 2) {
            Text(count == 0 ? "Sélectionnez des carnets" : "\(count) sélectionné\(count > 1 ? "s" : "")")
                .font(.callout.weight(.medium))
                .padding(.horizontal, 10)
            Spacer(minLength: 8)
            Menu {
                Button("Aucun dossier") { for id in selection { store.move(id, to: nil) } }
                ForEach(store.folders) { folder in
                    Button(folder.name) { for id in selection { store.move(id, to: folder.id) } }
                }
            } label: {
                Label("Déplacer", systemImage: "folder")
            }
            Button {
                for id in selection where (store.notebook(id)?.isFavorite == true) == allFavorite {
                    store.toggleFavorite(id)
                }
            } label: {
                Label(allFavorite ? "Retirer des favoris" : "Favoris", systemImage: allFavorite ? "star.slash" : "star")
            }
            Button {
                mergeTitle = (orderedSelection.first.flatMap { store.notebook($0)?.title } ?? "Carnet") + " (fusion)"
                showMergePrompt = true
            } label: {
                Label("Fusionner", systemImage: "rectangle.stack.badge.plus")
            }
            .disabled(count < 2)
            Button {
                exportSelected()
            } label: {
                Label("Exporter", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                confirmBatchDelete = true
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
        .labelStyle(.iconOnly)
        .font(.body)
        .disabled(isBusy)
        .buttonStyle(.borderless)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassEffect(in: Capsule())
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
        .opacity(count == 0 ? 0.85 : 1)
    }

    private var isBusy: Bool { busyMessage != nil }

    private func exportSelected() {
        let notebooks = orderedSelection.compactMap { store.notebook($0) }
        guard !notebooks.isEmpty else { return }
        for notebook in notebooks { store.flush(notebook.id) }
        store.waitForPendingWrites()
        let jobs = notebooks.map { ($0, store.files(for: $0.id)) }
        busyMessage = "Exportation de \(notebooks.count) PDF…"
        Task {
            let urls = await Task.detached(priority: .userInitiated) { () -> [URL] in
                var result: [URL] = []
                for (notebook, files) in jobs {
                    let url = FileManager.default.temporaryDirectory
                        .appendingPathComponent(PageRenderer.exportFileName(notebook.title, ext: "pdf"))
                    try? FileManager.default.removeItem(at: url)
                    if (try? PageRenderer.exportPDF(notebook: notebook, files: files, drawings: nil, to: url)) != nil {
                        result.append(url)
                    }
                }
                return result
            }.value
            busyMessage = nil
            if !urls.isEmpty { sharedFiles = SharedFiles(urls: urls) }
        }
    }

    // MARK: Actions

    private func openNotebook(_ id: UUID, page: Int? = nil) {
        router.openNotebook(id, page: page)
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
                    let notebook = try await store.importPDF(from: url, folderID: folder)
                    if notebook.origin == .goodNotes { ImportedTextRecognizer.shared.enqueueAllPages(of: notebook.id) }
                    imported.append(notebook)
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
                let notebook = try await store.importImages(images, title: title, folderID: folder, origin: .scan)
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
