import Foundation
import PencilKit

// MARK: - HandwritingIndexer
// Keeps every page's recognised handwriting up to date so the library can search it.
// Uses the on-device PencilKit recogniser (iOS 27): nothing leaves the device.

final class HandwritingIndexer {
    static let shared = HandwritingIndexer()

    private var queue: [UUID: Set<UUID>] = [:]          // notebook -> pages
    private var inMemory: [UUID: PKDrawing] = [:]       // fresher than disk while editing
    private var worker: Task<Void, Never>?

    /// Languages configured in Settings, as recogniser languages.
    static var languages: [Locale.Language] {
        CarnetsSettings.shared.recognitionLanguages.map { Locale.Language(identifier: $0) }
    }

    /// Queues pages for (re)recognition. `drawings` lets the editor hand over unsaved ink.
    func schedule(notebookID: UUID, pageIDs: some Sequence<UUID>, drawings: [UUID: PKDrawing] = [:]) {
        queue[notebookID, default: []].formUnion(pageIDs)
        for (id, drawing) in drawings { inMemory[id] = drawing }
        startIfNeeded()
    }

    /// Re-indexes pages recognised with an older engine, or never recognised.
    func refreshStalePages() {
        let version = PKStrokeRecognizer.recognitionVersion
        for notebook in NotebookStore.shared.notebooks {
            let stale = notebook.pages.filter { $0.recognitionVersion < version }.map(\.id)
            if !stale.isEmpty { schedule(notebookID: notebook.id, pageIDs: stale) }
        }
    }

    func reindexEverything() {
        for notebook in NotebookStore.shared.notebooks {
            schedule(notebookID: notebook.id, pageIDs: notebook.pages.map(\.id))
        }
    }

    private func startIfNeeded() {
        guard worker == nil else { return }
        worker = Task { [weak self] in
            // Let the writer finish their thought before spending energy on recognition.
            try? await Task.sleep(for: .seconds(2))
            await self?.drain()
            self?.worker = nil
            if let self, !self.queue.isEmpty { self.startIfNeeded() }
        }
    }

    private func drain() async {
        let store = NotebookStore.shared
        while let entry = queue.first {
            let notebookID = entry.key
            let pageIDs = entry.value
            queue[notebookID] = nil
            let files = store.files(for: notebookID)
            for pageID in pageIDs {
                guard store.notebook(notebookID)?.pages.contains(where: { $0.id == pageID }) == true else { continue }
                let drawing: PKDrawing
                if let fresh = inMemory.removeValue(forKey: pageID) {
                    drawing = fresh
                } else {
                    let url = files.drawingURL(pageID)
                    drawing = await Task.detached(priority: .utility) { DrawingIO.load(url) ?? PKDrawing() }.value
                }
                let result = await Self.recognize(drawing, languages: Self.languages)
                store.update(notebookID, touch: false) { notebook in
                    guard let index = notebook.pages.firstIndex(where: { $0.id == pageID }) else { return }
                    notebook.pages[index].recognizedText = result.text
                    notebook.pages[index].searchableText = result.searchable
                    notebook.pages[index].recognitionVersion = PKStrokeRecognizer.recognitionVersion
                }
            }
        }
    }

    /// Recognises a whole drawing. Returns the best reading and an index string with alternates.
    nonisolated static func recognize(_ drawing: PKDrawing, languages: [Locale.Language]) async -> (text: String, searchable: String) {
        guard !drawing.strokes.isEmpty else { return ("", "") }
        let recognizer = PKStrokeRecognizer(preferredLanguages: languages)
        await recognizer.updateDrawing(drawing)
        let text = await recognizer.recognizedText(strokeIDs: nil) ?? ""
        let searchable = await recognizer.indexableContent ?? text
        return (text, searchable)
    }
}

// MARK: - Library search

nonisolated struct SearchMatch: Identifiable, Sendable {
    nonisolated enum Source: Sendable { case title, handwriting, pdfText, typedText }

    let id = UUID()
    let notebookID: UUID
    let pageIndex: Int?
    let source: Source
    let snippet: String
}

nonisolated enum LibrarySearch {
    static func normalized(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }

    static func search(_ query: String, in notebooks: [Notebook]) -> [SearchMatch] {
        let q = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !q.isEmpty else { return [] }
        var matches: [SearchMatch] = []
        for notebook in notebooks {
            if normalized(notebook.title).contains(q) {
                matches.append(SearchMatch(notebookID: notebook.id, pageIndex: nil, source: .title, snippet: notebook.title))
            }
            for (index, page) in notebook.pages.enumerated() {
                if normalized(page.searchableText).contains(q) || normalized(page.recognizedText).contains(q) {
                    let text = page.recognizedText.isEmpty ? page.searchableText : page.recognizedText
                    matches.append(SearchMatch(notebookID: notebook.id, pageIndex: index, source: .handwriting,
                                               snippet: snippet(text, around: q)))
                }
                if normalized(page.sourceText).contains(q) {
                    matches.append(SearchMatch(notebookID: notebook.id, pageIndex: index, source: .pdfText,
                                               snippet: snippet(page.sourceText, around: q)))
                }
                let typed = page.elements.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
                if normalized(typed).contains(q) {
                    matches.append(SearchMatch(notebookID: notebook.id, pageIndex: index, source: .typedText,
                                               snippet: snippet(typed, around: q)))
                }
            }
        }
        return matches
    }

    /// About 90 characters of context around the first occurrence.
    static func snippet(_ text: String, around query: String) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let range = flat.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(flat.prefix(90))
        }
        let start = flat.index(range.lowerBound, offsetBy: -40, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(range.upperBound, offsetBy: 50, limitedBy: flat.endIndex) ?? flat.endIndex
        var result = String(flat[start..<end]).trimmingCharacters(in: .whitespaces)
        if start != flat.startIndex { result = "…" + result }
        if end != flat.endIndex { result += "…" }
        return result
    }
}
