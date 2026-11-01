import Foundation
import UIKit
import PencilKit

// MARK: - NotebookVaultBridge
// Mirrors every handwritten notebook into the vault as `Carnets/<Titre>.md`:
// front matter, a link that reopens the notebook in Carnets, an image of every page
// that has content, and the recognised handwriting under each image. Obsidian (or any
// Markdown viewer on your server) can then display, search and link to your handwriting.
// Anything you write outside the generated block is preserved.

final class NotebookVaultBridge {
    static let shared = NotebookVaultBridge()

    static let beginMarker = "<!-- carnets:début — section générée par Carnets, modifiez en dehors -->"
    static let endMarker = "<!-- carnets:fin -->"

    private var pending: Set<UUID> = []
    private var worker: Task<Void, Never>?

    func schedule(_ id: UUID) {
        // The iPad writes the notes; readers receive them through sync.
        guard !NotebookStore.shared.isReadOnly else { return }
        pending.insert(id)
        worker?.cancel()
        worker = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            await self?.processPending()
        }
    }

    /// Exports every notebook (e.g. after the vault moved).
    func exportAll() {
        guard !NotebookStore.shared.isReadOnly else { return }
        for notebook in NotebookStore.shared.notebooks { pending.insert(notebook.id) }
        schedule(pending.first ?? UUID())
    }

    func notebookDeleted(_ id: UUID) {
        pending.remove(id)
        if let path = companionPath(for: id) { VaultStore.shared.trash(path) }
    }

    func companionPath(for id: UUID) -> String? {
        VaultStore.shared.notes.first { $0.notebookID == id }?.path
    }

    private func processPending() async {
        // The vault index must be loaded, or we'd create duplicate notes.
        while VaultStore.shared.isScanning {
            try? await Task.sleep(for: .milliseconds(300))
        }
        // Ids leave `pending` one at a time: if a newer schedule cancels this run,
        // the notebooks not yet exported are picked up by the next one.
        for id in pending {
            guard !Task.isCancelled else { return }
            pending.remove(id)
            await export(id)
        }
    }

    private func export(_ id: UUID) async {
        let store = NotebookStore.shared
        guard let notebook = store.notebook(id) else { return }
        let files = store.files(for: id)
        await store.pendingWritesFlushed()
        let images = await Task.detached(priority: .utility) {
            PageImageExporter.renderPages(of: notebook, files: files)
        }.value

        let vault = VaultStore.shared
        var path = companionPath(for: id) ?? vault.uniquePath(folder: VaultPaths.carnets, title: notebook.title)
        if vault.note(path) != nil, VaultPaths.title(of: path) != VaultPaths.sanitizedName(notebook.title) {
            path = vault.renameNote(path, to: notebook.title)
        }
        let previous = vault.exists(path) ? vault.text(of: path) : ""
        let generated = Self.markdown(for: notebook, images: images)
        let merged = Self.merge(previous: previous, generated: generated)
        if merged != previous {
            vault.save(merged, to: path)
        }
    }

    // MARK: Markdown

    static func markdown(for notebook: Notebook, images: [UUID: String]) -> (frontmatter: [(String, String)], body: String) {
        let iso = ISO8601DateFormatter()
        let data = "Données/\(notebook.id.uuidString)"
        let frontmatter: [(String, String)] = [
            ("carnets-id", notebook.id.uuidString),
            ("type", "carnet-manuscrit"),
            ("pages", "\(notebook.pages.count)"),
            ("created", iso.string(from: notebook.createdAt)),
            ("modified", iso.string(from: notebook.modifiedAt)),
            ("tags", "[carnet]"),
        ]
        var lines: [String] = [beginMarker, "# \(notebook.title)", ""]
        let count = notebook.pages.count
        let origin = notebook.source.map { " · importé de \($0.origin.label)" } ?? ""
        lines.append("> Carnet manuscrit · \(count) page\(count > 1 ? "s" : "")\(origin) · [Ouvrir dans Carnets](carnets://carnet/\(notebook.id.uuidString))")
        var pdfs: [String] = []
        for page in notebook.pages {
            if case .pdf(let file, _) = page.background, !pdfs.contains(file) { pdfs.append(file) }
        }
        for file in pdfs {
            lines.append("> PDF d’origine : [[\(VaultPaths.carnetsData)/\(notebook.id.uuidString)/assets/\(file)|\(file)]]")
        }
        lines.append("")
        for (index, page) in notebook.pages.enumerated() {
            guard let image = images[page.id] else { continue }
            let title = page.title.isEmpty ? "" : " — \(page.title)"
            lines.append("## Page \(index + 1)\(title)\(page.isBookmarked ? " 🔖" : "")")
            lines.append("![Page \(index + 1)](<\(data)/pages/\(image)>)")
            let typed = page.elements.filter { $0.kind == .text }.map(\.text).filter { !$0.isEmpty }
            let recognized = page.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines)
            // Handwriting imported from GoodNotes was read from the page image.
            let imported = notebook.origin == .goodNotes ? page.sourceText.trimmingCharacters(in: .whitespacesAndNewlines) : ""
            let paragraphs = typed + [imported, recognized].filter { !$0.isEmpty }
            if !paragraphs.isEmpty {
                lines.append("")
                for paragraph in paragraphs {
                    lines.append(paragraph.trimmingCharacters(in: .whitespacesAndNewlines))
                    lines.append("")
                }
            } else {
                lines.append("")
            }
        }
        if images.isEmpty {
            lines.append("*Ce carnet ne contient pas encore d’écriture.*")
            lines.append("")
        }
        lines.append(endMarker)
        return (frontmatter, lines.joined(separator: "\n"))
    }

    /// Replaces the generated block and front matter keys, keeping everything the user added.
    static func merge(previous: String, generated: (frontmatter: [(String, String)], body: String)) -> String {
        let generatedKeys = Set(generated.frontmatter.map(\.0))
        var userFrontmatter: [String] = []
        var rest = previous
        let ns = previous as NSString
        if let range = MarkdownSyntax.frontmatterRange(in: ns) {
            let block = ns.substring(with: range)
            var skipping = false
            for line in block.components(separatedBy: "\n").dropFirst() {
                if line.hasPrefix("---") { break }
                if let colon = line.firstIndex(of: ":"), !line.hasPrefix(" "), !line.hasPrefix("-") {
                    let key = line[..<colon].trimmingCharacters(in: .whitespaces)
                    skipping = generatedKeys.contains(key)
                }
                if !skipping && !line.trimmingCharacters(in: .whitespaces).isEmpty { userFrontmatter.append(line) }
            }
            rest = ns.substring(from: range.location + range.length)
        }
        var before = ""
        var after = ""
        if let start = rest.range(of: "<!-- carnets:début"), let end = rest.range(of: endMarker) {
            before = String(rest[..<start.lowerBound])
            after = String(rest[end.upperBound...])
        } else if !rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            after = "\n\n" + rest
        }
        var frontmatter = ["---"]
        frontmatter += generated.frontmatter.map { "\($0.0): \($0.1)" }
        frontmatter += userFrontmatter
        frontmatter.append("---")
        var result = frontmatter.joined(separator: "\n") + "\n"
        result += before + generated.body + after
        if !result.hasSuffix("\n") { result += "\n" }
        return result
    }
}

// MARK: - Page renders for the vault

nonisolated enum PageImageExporter {
    /// Renders pages that have content (ink, text boxes, photos or scans) to JPEG,
    /// re-rendering only pages whose revision changed. Returns page id → file name.
    static func renderPages(of notebook: Notebook, files: NotebookFiles) -> [UUID: String] {
        let fm = FileManager.default
        let folder = files.directory.appendingPathComponent("pages", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let indexURL = folder.appendingPathComponent("rendered.json")
        var rendered: [String: Int] = [:]
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([String: Int].self, from: data) {
            rendered = decoded
        }
        var result: [UUID: String] = [:]
        for page in notebook.pages {
            let inkSize = (try? files.drawingURL(page.id).resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            var isScan = false
            if case .image = page.background { isScan = true }
            // Every page of a GoodNotes notebook carries handwriting, even without Carnets ink.
            let isImportedHandwriting = notebook.origin == .goodNotes
            guard inkSize > 0 || !page.elements.isEmpty || isScan || isImportedHandwriting else { continue }
            let name = "\(page.id.uuidString).jpg"
            result[page.id] = name
            let target = folder.appendingPathComponent(name)
            if rendered[page.id.uuidString] == page.revision, fm.fileExists(atPath: target.path) { continue }
            let scale = min(2, (isImportedHandwriting && inkSize == 0 ? 1100 : 1400) / max(page.size.width, 1))
            let image = PageRenderer.renderPage(page: page, files: files, drawing: nil, scale: scale)
            if let data = image.jpegData(compressionQuality: 0.72) {
                try? data.write(to: target, options: .atomic)
                rendered[page.id.uuidString] = page.revision
            }
        }
        // Remove renders of deleted or emptied pages.
        let keep = Set(result.values)
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        where url.pathExtension == "jpg" && !keep.contains(url.lastPathComponent) {
            try? fm.removeItem(at: url)
        }
        rendered = rendered.filter { keep.contains("\($0.key).jpg") }
        if let data = try? JSONEncoder().encode(rendered) { try? data.write(to: indexURL, options: .atomic) }
        return result
    }
}
