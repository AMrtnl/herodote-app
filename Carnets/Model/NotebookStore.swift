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

    @ObservationIgnored let rootURL: URL
    @ObservationIgnored private let ioQueue = DispatchQueue(label: "carnets.store.io", qos: .utility)
    @ObservationIgnored private var pendingSaves: [UUID: Task<Void, Never>] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        rootURL = support.appendingPathComponent("Carnets", isDirectory: true)
        try? FileManager.default.createDirectory(at: notebooksURL, withIntermediateDirectories: true)
        load()
    }

    // MARK: Paths

    var notebooksURL: URL { rootURL.appendingPathComponent("Notebooks", isDirectory: true) }
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
    func importPDF(from url: URL, folderID: UUID?) async throws -> Notebook {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var notebook = Notebook(title: url.deletingPathExtension().lastPathComponent, cover: nil,
                                template: .blank, paper: .white, format: .a4, landscape: false,
                                folderID: folderID)
        let files = self.files(for: notebook.id)
        do {
            notebook.pages = try await Task.detached(priority: .userInitiated) {
                try Importer.importPDF(from: url, into: files)
            }.value
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

    /// Creates a notebook whose pages are the given images (photos or scanned documents).
    func importImages(_ images: [UIImage], title: String, folderID: UUID?) async throws -> Notebook {
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
        ioQueue.async {
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
