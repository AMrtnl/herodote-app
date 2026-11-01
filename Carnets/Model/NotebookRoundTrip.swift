import Foundation
import PencilKit

// MARK: - Round trips with GoodNotes
// "Envoyer vers GoodNotes" flattens Carnets ink into the PDF. When a GoodNotes export of
// that PDF comes back, the Carnets ink is already printed on the pages: the record below
// lets the update remove exactly those strokes and boxes, so nothing appears twice.

nonisolated struct FlattenedExport: Codable, Sendable {
    var exportedAt: Date
    /// Page ids in exported order: page i of the PDF is `order[i]`.
    var order: [UUID]
    /// Stroke ids printed into the PDF, per page id.
    var strokes: [String: [UUID]]
    /// Text boxes and photos printed into the PDF, per page id.
    var elements: [String: [UUID]]

    static func url(in files: NotebookFiles) -> URL {
        files.directory.appendingPathComponent("exports", isDirectory: true)
            .appendingPathComponent("envoi-goodnotes.json")
    }

    static func load(from files: NotebookFiles) -> FlattenedExport? {
        guard let data = try? Data(contentsOf: url(in: files)) else { return nil }
        return try? NotebookStore.decoder().decode(FlattenedExport.self, from: data)
    }

    static func remove(from files: NotebookFiles) {
        try? FileManager.default.removeItem(at: url(in: files))
    }

    func save(to files: NotebookFiles) {
        let target = Self.url(in: files)
        try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? NotebookStore.encoder().encode(self) {
            try? data.write(to: target, options: .atomic)
        }
    }

    /// Notes what an export of `notebook` prints (reads the ink files; call off the main thread).
    static func record(_ notebook: Notebook, files: NotebookFiles) -> FlattenedExport {
        var strokes: [String: [UUID]] = [:]
        var elements: [String: [UUID]] = [:]
        for page in notebook.pages {
            if let drawing = DrawingIO.load(files.drawingURL(page.id)), !drawing.strokes.isEmpty {
                strokes[page.id.uuidString] = drawing.strokes.map { $0.id }
            }
            if !page.elements.isEmpty {
                elements[page.id.uuidString] = page.elements.map { $0.id }
            }
        }
        return FlattenedExport(exportedAt: .now, order: notebook.pages.map { $0.id }, strokes: strokes, elements: elements)
    }

    /// Removes the printed strokes from the ink files of the given pages.
    func stripPrintedInk(pageIDs: [UUID], files: NotebookFiles) {
        for id in pageIDs {
            guard let printed = strokes[id.uuidString], !printed.isEmpty,
                  let drawing = DrawingIO.load(files.drawingURL(id)) else { continue }
            let printedSet = Set(printed)
            let kept = drawing.strokes.filter { !printedSet.contains($0.id) }
            guard kept.count != drawing.strokes.count else { continue }
            let data = kept.isEmpty ? Data() : PKDrawing(strokes: kept).dataRepresentation()
            DrawingIO.write([id: data], files: files)
        }
    }
}

// MARK: - Matching pages of a newer export

nonisolated enum PagePairing {
    nonisolated struct Result: Sendable {
        var pages: [NotebookPage]
        /// Pages (already in the notebook) that now show a page of the new export.
        var updatedPageIDs: [UUID]
    }

    /// Builds the page list after a newer export replaces an imported PDF.
    /// - Pages showing page *i* of the previous PDF now show page *i* of the new one, keeping
    ///   their id (so their ink), text boxes, bookmark and title.
    /// - Pages added in Carnets (blank, photos, other PDFs) stay where they are.
    /// - Pages added at the end in GoodNotes are inserted after the page that precedes them.
    /// - With `flattened`, the new PDF is GoodNotes' export of a Carnets export: pages are
    ///   matched by position in that export, and boxes already printed are dropped.
    static func merge(old: [NotebookPage], fresh: [NotebookPage], previousFile: String?,
                      flattened: FlattenedExport?, pagesWithInk: Set<UUID>) -> Result {
        var freshIndexFor: [UUID: Int] = [:]
        if let flattened {
            let existing = Set(old.map { $0.id })
            for (index, id) in flattened.order.enumerated() where index < fresh.count && existing.contains(id) {
                freshIndexFor[id] = index
            }
        } else {
            var used = Set<Int>()
            for page in old {
                guard case .pdf(let file, let index) = page.background,
                      previousFile == nil || file == previousFile,
                      index < fresh.count, !used.contains(index) else { continue }
                freshIndexFor[page.id] = index
                used.insert(index)
            }
        }

        var pages: [NotebookPage] = []
        var origins: [Int?] = []
        var updated: [UUID] = []
        for page in old {
            if let index = freshIndexFor[page.id] {
                var replacement = fresh[index]
                replacement.id = page.id
                let printed = Set(flattened?.elements[page.id.uuidString] ?? [])
                replacement.elements = page.elements.filter { !printed.contains($0.id) }
                replacement.isBookmarked = page.isBookmarked
                replacement.title = page.title
                replacement.recognizedText = page.recognizedText
                replacement.searchableText = page.searchableText
                replacement.recognitionVersion = page.recognitionVersion
                replacement.revision = page.revision + 1
                pages.append(replacement)
                origins.append(index)
                updated.append(page.id)
                continue
            }
            var showsPreviousPDF = false
            var previousIndex = 0
            if case .pdf(let file, let index) = page.background, previousFile == nil || file == previousFile {
                showsPreviousPDF = true
                previousIndex = index
            }
            guard showsPreviousPDF else {
                pages.append(page)
                origins.append(nil)
                continue
            }
            // A page of the previous PDF with no counterpart (duplicated in Carnets, or removed
            // in GoodNotes): the previous file is about to be deleted.
            var kept = page
            if flattened == nil, previousIndex < fresh.count {
                kept.background = fresh[previousIndex].background
                kept.width = fresh[previousIndex].width
                kept.height = fresh[previousIndex].height
            } else if pagesWithInk.contains(page.id) || !page.elements.isEmpty {
                kept.background = .template(.blank)
            } else {
                continue
            }
            kept.revision += 1
            pages.append(kept)
            origins.append(nil)
            updated.append(page.id)
        }

        // Pages that are new in the export.
        for index in fresh.indices where !origins.contains(index) {
            let position: Int
            if index > 0, let previous = origins.firstIndex(of: index - 1) {
                position = previous + 1
            } else if index == 0 {
                position = origins.firstIndex { $0 != nil } ?? pages.count
            } else {
                position = pages.count
            }
            pages.insert(fresh[index], at: position)
            origins.insert(index, at: position)
        }
        return Result(pages: pages, updatedPageIDs: updated)
    }
}
