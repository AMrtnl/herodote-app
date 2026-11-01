import Foundation
import Observation
import UIKit
import Vision

// MARK: - Text recognition for imported pages
// Handwriting exported from GoodNotes is flattened into the PDF, so PencilKit can't read it.
// Vision's on-device text recognition (which handles handwriting) makes it searchable instead;
// the result goes into `sourceText`, used by search and by the notebook's note in the vault.

nonisolated enum PageTextRecognizer {
    /// Vision language codes for the recognition languages chosen in Settings.
    static func visionLanguages(for codes: [String]) -> [String] {
        let map = ["fr": "fr-FR", "en": "en-US", "de": "de-DE", "es": "es-ES", "it": "it-IT", "pt": "pt-BR"]
        let result = codes.compactMap { map[$0] }
        return result.isEmpty ? ["fr-FR", "en-US"] : result
    }

    static func recognize(page: NotebookPage, files: NotebookFiles, languages: [String]) -> String {
        let scale = min(2.5, 2200 / max(page.size.width, 1))
        let image = PageRenderer.renderBackground(page: page, files: files, region: page.bounds, scale: scale)
        guard let cgImage = image.cgImage else { return "" }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = languages
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

@Observable final class ImportedTextRecognizer {
    static let shared = ImportedTextRecognizer()

    /// Pages still waiting for recognition (shown in the import sheet).
    private(set) var remaining = 0

    @ObservationIgnored private var queue: [(notebook: UUID, page: UUID)] = []
    @ObservationIgnored private var worker: Task<Void, Never>?

    private init() {}

    /// Queues pages whose background (PDF or scan) should be read.
    func enqueue(notebookID: UUID, pageIDs: [UUID]) {
        for page in pageIDs where !queue.contains(where: { $0.notebook == notebookID && $0.page == page }) {
            queue.append((notebook: notebookID, page: page))
        }
        remaining = queue.count
        guard worker == nil else { return }
        worker = Task { [weak self] in
            await self?.drain()
            self?.worker = nil
        }
    }

    func enqueueAllPages(of notebookID: UUID) {
        guard let notebook = NotebookStore.shared.notebook(notebookID) else { return }
        let pages = notebook.pages.filter { !$0.background.isTemplate }.map(\.id)
        enqueue(notebookID: notebookID, pageIDs: pages)
    }

    private func drain() async {
        let store = NotebookStore.shared
        while !queue.isEmpty {
            let item = queue.removeFirst()
            remaining = queue.count
            guard let notebook = store.notebook(item.notebook),
                  let page = notebook.pages.first(where: { $0.id == item.page }),
                  !page.background.isTemplate else { continue }
            let files = store.files(for: item.notebook)
            let languages = PageTextRecognizer.visionLanguages(for: CarnetsSettings.shared.recognitionLanguages)
            let recognized = await Task.detached(priority: .utility) {
                PageTextRecognizer.recognize(page: page, files: files, languages: languages)
            }.value
            guard !recognized.isEmpty else { continue }
            store.update(item.notebook, touch: false) { notebook in
                guard let index = notebook.pages.firstIndex(where: { $0.id == item.page }) else { return }
                let existing = notebook.pages[index].sourceText
                // Keep text the PDF already had (typed text) and add what was read from the image.
                notebook.pages[index].sourceText = existing.isEmpty || existing.contains(recognized)
                    ? recognized
                    : existing + "\n" + recognized
            }
        }
        remaining = 0
    }
}
