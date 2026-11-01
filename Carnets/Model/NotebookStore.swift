import Foundation
import Observation
import UIKit
import PencilKit

// MARK: - NotebookStore
// Single source of truth for notebook metadata. Ink lives in per-page drawing
// files that the editor reads and writes directly (see `DrawingIO`).

@Observable final class NotebookStore {
    static let shared = NotebookStore()

    private(set) var notebooks: [Notebook] = []
    private(set) var folders: [Folder] = []

    /// `<Vault>/Carnets/Données`: one folder per notebook (ink, PDFs, page renders).
    @ObservationIgnored private(set) var rootURL: URL
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "carnets.store.io", qos: .utility)
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    private init() {
        rootURL = VaultStore.shared.url(for: VaultPaths.carnetsData)
        try? FileManager.default.createDirectory(at: notebooksURL, withIntermediateDirectories: true)
        Self.migrateLegacyStorage(into: rootURL)
        load()
    }

    /// Re-reads everything after the vault moved or was synced.
    func reload() {
        flushAll()
        waitForPendingWrites()
        rootURL = VaultStore.shared.url(for: VaultPaths.carnetsData)
        try? FileManager.default.createDirectory(at: notebooksURL, withIntermediateDirectories: true)
        notebooks = []
        folders = []
        load()
    }

    /// Notebooks created before the vault existed lived in Application Support.
    private static func migrateLegacyStorage(into destination: URL) {
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Carnets", isDirectory: true)
        let legacyNotebooks = legacy.appendingPathComponent("Notebooks", isDirectory: true)
        guard let items = try? fm.contentsOfDirectory(at: legacyNotebooks, includingPropertiesForKeys: nil), !items.isEmpty else { return }
        for item in items where !fm.fileExists(atPath: destination.appendingPathComponent(item.lastPathComponent).path) {
            try? fm.moveItem(at: item, to: destination.appendingPathComponent(item.lastPathComponent))
        }
        let legacyLibrary = legacy.appendingPathComponent("library.json")
        let newLibrary = destination.appendingPathComponent("library.json")
        if fm.fileExists(atPath: legacyLibrary.path) && !fm.fileExists(atPath: newLibrary.path) {
            try? fm.moveItem(at: legacyLibrary, to: newLibrary)
        }
        try? fm.removeItem(at: legacyNotebooks)
    }

    // MARK: Paths

    var notebooksURL: URL { rootURL }
    private var libraryURL: URL { rootURL.appendingPathComponent("library.json") }

    func files(for id: UUID) -> NotebookFiles {
        NotebookFiles(directory: notebooksURL.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    // MARK: Queries

    func notebook(_ id: UUID) -> Notebook? {
        notebooks.first { $0.id == id }
    }

    func notebooks(in folderID: UUID?) -> [Notebook] {
        notebooks.filter { $0.folderID == folderID }
    }

    func folder(_ id: UUID) -> Folder? {
        folders.first { $0.id == id }
    }

    // MARK: Mutation

    /// Mutates a notebook in place and schedules a save.
    /// `touch` updates the modification date (used for sorting).
    func update(_ id: UUID, touch: Bool = true, _ body: (inout Notebook) -> Void) {
        guard let index = notebooks.firstIndex(where: { $0.id == id }) else { return }
        body(&notebooks[index])
        if touch { notebooks[index].modifiedAt = .now }
        scheduleSave(id)
    }

    @discardableResult
    func createNotebook(title: String, cover: CoverStyle?, template: PageTemplate, paper: PaperStyle,
                        format: PageFormat, landscape: Bool, folderID: UUID?) -> Notebook {
        var notebook = Notebook(title: title, cover: cover, template: template, paper: paper,
                                format: format, landscape: landscape, folderID: folderID)
        notebook.pages = [notebook.makeDefaultPage()]
        insert(notebook)
        return notebook
    }

    /// Imports a PDF as a new notebook (pages keep the PDF as background, ready to annotate).
    /// PDFs exported from GoodNotes are recognised and marked as such.
    func importPDF(from url: URL, title: String? = nil, folderID: UUID?) async throws -> Notebook {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var notebook = Notebook(title: title ?? url.deletingPathExtension().lastPathComponent, cover: nil,
                                template: .blank, paper: .white, format: .a4, landscape: false,
                                folderID: folderID)
        let files = self.files(for: notebook.id)
        do {
            let result = try await Task.detached(priority: .userInitiated) { () -> ([NotebookPage], Bool) in
                let pages = try Importer.importPDF(from: url, into: files)
                return (pages, GoodNotesImporter.isGoodNotesPDF(url))
            }.value
            notebook.pages = result.0
            notebook.source = NotebookSource(origin: result.1 ? .goodNotes : .pdf,
                                             originalName: url.lastPathComponent,
                                             originalFile: Self.pdfFile(of: result.0))
        } catch {
            try? FileManager.default.removeItem(at: files.directory)
            throw error
        }
        if let first = notebook.pages.first {
            notebook.defaultFormat = first.width <= 430 ? .a5 : .a4
            notebook.landscape = first.width > first.height
        }
        insert(notebook)
        return notebook
    }

    private static func pdfFile(of pages: [NotebookPage]) -> String? {
        for page in pages {
            if case .pdf(let file, _) = page.background { return file }
        }
        return nil
    }

    /// Replaces the pages of an imported notebook with a newer export of the same document.
    /// Ink, text boxes, photos and bookmarks added in Carnets stay on the same page numbers.
    @discardableResult
    func updateNotebook(_ id: UUID, fromPDF url: URL) async throws -> Notebook? {
        guard notebook(id) != nil else { return nil }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        flush(id)
        let files = self.files(for: id)
        let result = try await Task.detached(priority: .userInitiated) { () -> ([NotebookPage], Bool) in
            let pages = try Importer.importPDF(from: url, into: files)
            return (pages, GoodNotesImporter.isGoodNotesPDF(url))
        }.value
        let fresh = result.0
        update(id) { notebook in
            var merged: [NotebookPage] = []
            for (index, page) in fresh.enumerated() {
                var updated = page
                if notebook.pages.indices.contains(index) {
                    let previous = notebook.pages[index]
                    updated.id = previous.id
                    updated.elements = previous.elements
                    updated.isBookmarked = previous.isBookmarked
                    updated.recognizedText = previous.recognizedText
                    updated.searchableText = previous.searchableText
                    updated.recognitionVersion = previous.recognitionVersion
                    updated.revision = previous.revision + 1
                }
                merged.append(updated)
            }
            if notebook.pages.count > fresh.count {
                merged += notebook.pages[fresh.count...]
            }
            notebook.pages = merged
            var source = notebook.source ?? NotebookSource(origin: result.1 ? .goodNotes : .pdf)
            if result.1 { source.origin = .goodNotes }
            source.originalName = url.lastPathComponent
            source.originalFile = Self.pdfFile(of: fresh)
            source.updatedAt = .now
            notebook.source = source
        }
        collectGarbage(id)
        return notebook(id)
    }

    /// An already imported notebook that a new export of `fileName` should update.
    func importedNotebook(matching fileName: String) -> Notebook? {
        let stem = (fileName as NSString).deletingPathExtension.lowercased()
        return notebooks.first { notebook in
            guard let source = notebook.source, source.origin == .goodNotes || source.origin == .pdf else { return false }
            let original = ((source.originalName ?? "") as NSString).deletingPathExtension.lowercased()
            return original == stem || notebook.title.lowercased() == stem
        }
    }

    /// Finds or creates the folder for an exported folder path (nested folders are shown as "A › B").
    func folderID(forPath components: [String]) -> UUID? {
        let name = components.filter { !$0.isEmpty }.joined(separator: " › ")
        guard !name.isEmpty else { return nil }
        if let existing = folders.first(where: { $0.name == name }) { return existing.id }
        return createFolder(named: name).id
    }

    /// Combines several notebooks, in order, into a new one. The originals are kept.
    @discardableResult
    func merge(_ ids: [UUID], title: String) -> Notebook? {
        let sources = ids.compactMap { notebook($0) }
        guard sources.count >= 2, let first = sources.first else { return nil }
        for source in sources { flush(source.id) }
        var merged = Notebook(title: title, cover: first.cover ?? .graphite, template: first.defaultTemplate,
                              paper: first.defaultPaper, format: first.defaultFormat, landscape: first.landscape,
                              folderID: first.folderID)
        let target = files(for: merged.id)
        target.createDirectories()
        var copies: [(URL, URL)] = []
        var pages: [NotebookPage] = []
        for source in sources {
            let sourceFiles = files(for: source.id)
            let assets = (try? FileManager.default.contentsOfDirectory(at: sourceFiles.assetsDirectory,
                                                                      includingPropertiesForKeys: nil)) ?? []
            for asset in assets { copies.append((asset, target.assetURL(asset.lastPathComponent))) }
            for page in source.pages {
                var copy = page
                copy.id = UUID()
                copy.elements = page.elements.map { element in
                    var e = element
                    e.id = UUID()
                    return e
                }
                copies.append((sourceFiles.drawingURL(page.id), target.drawingURL(copy.id)))
                pages.append(copy)
            }
        }
        let pairs = copies
        ioQueue.sync {
            let fm = FileManager.default
            for (from, to) in pairs where fm.fileExists(atPath: from.path) && !fm.fileExists(atPath: to.path) {
                try? fm.copyItem(at: from, to: to)
            }
        }
        merged.pages = pages
        insert(merged)
        HandwritingIndexer.shared.schedule(notebookID: merged.id, pageIDs: pages.map(\.id))
        return merged
    }

    /// Creates a notebook whose pages are the given images (photos or scanned documents).
    func importImages(_ images: [UIImage], title: String, folderID: UUID?, origin: NotebookOrigin = .photos) async throws -> Notebook {
        var notebook = Notebook(title: title, cover: nil, template: .blank, paper: .white,
                                format: .a4, landscape: false, folderID: folderID)
        let files = self.files(for: notebook.id)
        let pages = await Task.detached(priority: .userInitiated) {
            Importer.imagePages(images, into: files)
        }.value
        guard !pages.isEmpty else {
            try? FileManager.default.removeItem(at: files.directory)
            throw CarnetsError.emptyImport
        }
        notebook.pages = pages
        notebook.source = NotebookSource(origin: origin)
        insert(notebook)
        return notebook
    }

    func rename(_ id: UUID, to title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id) { $0.title = trimmed }
    }

    func toggleFavorite(_ id: UUID) {
        update(id, touch: false) { $0.isFavorite.toggle() }
    }

    func move(_ id: UUID, to folderID: UUID?) {
        update(id, touch: false) { $0.folderID = folderID }
    }

    func setCover(_ id: UUID, _ cover: CoverStyle?) {
        update(id) { $0.cover = cover }
    }

    func markOpened(_ id: UUID) {
        update(id, touch: false) { $0.openedAt = .now }
    }

    @discardableResult
    func duplicate(_ id: UUID) -> Notebook? {
        guard let original = notebook(id) else { return nil }
        flush(id)
        var copy = original
        copy.id = UUID()
        copy.title = original.title + " (copie)"
        copy.createdAt = .now
        copy.modifiedAt = .now
        copy.openedAt = nil
        copy.isFavorite = false
        let source = files(for: id).directory
        let destination = files(for: copy.id).directory
        // Run synchronously on the I/O queue so the copy exists before the new JSON is written.
        ioQueue.sync {
            try? FileManager.default.copyItem(at: source, to: destination)
        }
        insert(copy)
        return copy
    }

    func delete(_ id: UUID) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = nil
        notebooks.removeAll { $0.id == id }
        let directory = files(for: id).directory
        ioQueue.async {
            try? FileManager.default.removeItem(at: directory)
        }
        NotebookVaultBridge.shared.notebookDeleted(id)
    }

    // MARK: Folders

    @discardableResult
    func createFolder(named name: String) -> Folder {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = Folder(name: trimmed.isEmpty ? "Nouveau dossier" : trimmed)
        folders.append(folder)
        saveLibrary()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        saveLibrary()
    }

    /// Deletes the folder; its notebooks move back to the library root.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for notebook in notebooks where notebook.folderID == id {
            move(notebook.id, to: nil)
        }
        saveLibrary()
    }

    // MARK: Persistence

    func scheduleSave(_ id: UUID) {
        pendingSaves[id]?.cancel()
        pendingSaves[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.writeMetadata(id)
        }
    }

    /// Writes a notebook's pending metadata immediately.
    func flush(_ id: UUID) {
        guard pendingSaves[id] != nil else { return }
        pendingSaves[id]?.cancel()
        writeMetadata(id)
    }

    func flushAll() {
        for id in Array(pendingSaves.keys) {
            flush(id)
        }
        saveLibrary()
    }

    /// Blocks until every queued write has reached the disk (used before exporting or duplicating).
    func waitForPendingWrites() {
        ioQueue.sync {}
    }

    /// Suspends until every write queued so far has reached the disk.
    func pendingWritesFlushed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async { continuation.resume() }
        }
    }

    /// Writes ink for a notebook on the store's serial I/O queue (keeps writes ordered).
    func writeDrawings(_ drawings: [UUID: Data], notebookID: UUID) {
        guard !drawings.isEmpty else { return }
        let files = self.files(for: notebookID)
        ioQueue.async {
            DrawingIO.write(drawings, files: files)
        }
    }

    /// Removes drawings and assets no page references any more.
    func collectGarbage(_ id: UUID) {
        guard let notebook = notebook(id) else { return }
        var drawingNames = Set<String>()
        var assetNames = Set<String>()
        for page in notebook.pages {
            drawingNames.insert("\(page.id.uuidString).drawing")
            switch page.background {
            case .pdf(let file, _): assetNames.insert(file)
            case .image(let file):  assetNames.insert(file)
            case .template:         break
            }
            for element in page.elements {
                if let file = element.file { assetNames.insert(file) }
            }
        }
        let files = self.files(for: id)
        ioQueue.async { [drawingNames, assetNames] in
            let fm = FileManager.default
            for url in (try? fm.contentsOfDirectory(at: files.drawingsDirectory, includingPropertiesForKeys: nil)) ?? []
            where !drawingNames.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
            for url in (try? fm.contentsOfDirectory(at: files.assetsDirectory, includingPropertiesForKeys: nil)) ?? []
            where !assetNames.contains(url.lastPathComponent) {
                try? fm.removeItem(at: url)
            }
        }
    }

    private func insert(_ notebook: Notebook) {
        notebooks.append(notebook)
        files(for: notebook.id).createDirectories()
        writeMetadata(notebook.id)
    }

    private func writeMetadata(_ id: UUID) {
        pendingSaves[id] = nil
        guard let notebook = notebook(id), let data = try? Self.encoder().encode(notebook) else { return }
        let files = self.files(for: id)
        ioQueue.async {
            try? FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
            try? data.write(to: files.metadataURL, options: .atomic)
        }
        NotebookVaultBridge.shared.schedule(id)
        SyncCenter.shared.localChangeOccurred()
    }

    private func saveLibrary() {
        guard let data = try? Self.encoder().encode(LibraryIndex(folders: folders)) else { return }
        let url = libraryURL
        ioQueue.async {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        let decoder = Self.decoder()
        if let data = try? Data(contentsOf: libraryURL),
           let index = try? decoder.decode(LibraryIndex.self, from: data) {
            folders = index.folders
        }
        let directories = (try? FileManager.default.contentsOfDirectory(
            at: notebooksURL, includingPropertiesForKeys: nil)) ?? []
        notebooks = directories.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("notebook.json")) else { return nil }
            return try? decoder.decode(Notebook.self, from: data)
        }
        if notebooks.isEmpty && !UserDefaults.standard.bool(forKey: "carnets.seeded") {
            UserDefaults.standard.set(true, forKey: "carnets.seeded")
            seedWelcomeNotebook()
        }
    }

    nonisolated static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    nonisolated static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    // MARK: Welcome notebook

    private func seedWelcomeNotebook() {
        var notebook = Notebook(title: "Bienvenue dans Carnets", cover: .terracotta, template: .lined,
                                paper: .ivory, format: .a4, landscape: false, folderID: nil)
        let size = PageFormat.a4.portraitSize
        let ink = "#1C1C1E"

        var first = NotebookPage(size: size, background: .template(.lined), paper: .ivory)
        first.elements = [
            .makeText("Bienvenue dans Carnets", frame: CGRect(x: 56, y: 60, width: 480, height: 44),
                  fontSize: 30, style: .serif, colorHex: ink),
            .makeText("""
                  • Écrivez avec l’Apple Pencil — ou avec le doigt (menu ⋯ › Dessin au doigt).
                  • Pincez pour zoomer, faites défiler avec un doigt.
                  • Touchez l’écran avec deux doigts pour annuler, trois doigts pour rétablir.
                  • Double-touchez le Pencil pour passer à la gomme.
                  • Maintenez la pointe immobile en fin de trait : cercles, lignes et rectangles deviennent parfaits.
                  • Le lasso sélectionne l’écriture : déplacez-la, ou convertissez-la en texte.
                  • Recherchez dans vos notes manuscrites depuis la bibliothèque.
                  """,
                  frame: CGRect(x: 56, y: 130, width: 480, height: 300),
                  fontSize: 15, style: .sans, colorHex: "#3A3A3C"),
        ]
        var second = NotebookPage(size: size, background: .template(.grid), paper: .white)
        second.elements = [
            .makeText("Quadrillé, pointillé, Seyès, Cornell, partition… Changez le modèle de chaque page depuis l’aperçu des pages.",
                  frame: CGRect(x: 56, y: 56, width: 480, height: 60), fontSize: 15, style: .sans, colorHex: "#3A3A3C"),
        ]
        let third = NotebookPage(size: size, background: .template(.dots), paper: .eInk)
        notebook.pages = [first, second, third]
        insert(notebook)
    }
}
