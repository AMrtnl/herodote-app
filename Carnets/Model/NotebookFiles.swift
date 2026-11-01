import Foundation
import UIKit
import PDFKit
import PencilKit

// MARK: - On-disk layout of one notebook
//
//  Notebooks/<uuid>/
//      notebook.json          metadata + pages
//      drawings/<page>.drawing PKDrawing data, one file per page (page coordinates)
//      assets/<file>          imported PDFs, background images, placed photos

nonisolated struct NotebookFiles: Sendable {
    let directory: URL

    var metadataURL: URL { directory.appendingPathComponent("notebook.json") }
    var drawingsDirectory: URL { directory.appendingPathComponent("drawings", isDirectory: true) }
    var assetsDirectory: URL { directory.appendingPathComponent("assets", isDirectory: true) }

    func drawingURL(_ pageID: UUID) -> URL {
        drawingsDirectory.appendingPathComponent("\(pageID.uuidString).drawing")
    }

    func assetURL(_ name: String) -> URL {
        assetsDirectory.appendingPathComponent(name)
    }

    func createDirectories() {
        let fm = FileManager.default
        try? fm.createDirectory(at: drawingsDirectory, withIntermediateDirectories: true)
        try? fm.createDirectory(at: assetsDirectory, withIntermediateDirectories: true)
    }
}

// MARK: - Errors

nonisolated enum CarnetsError: LocalizedError {
    case unreadablePDF
    case lockedPDF
    case emptyImport
    case readOnly

    var errorDescription: String? {
        switch self {
        case .unreadablePDF: return "Ce fichier PDF ne peut pas être lu."
        case .lockedPDF:     return "Ce PDF est protégé par un mot de passe."
        case .emptyImport:   return "Aucune page n’a pu être importée."
        case .readOnly:      return "Les carnets se créent et se modifient sur iPad ; ici, ils sont en lecture seule."
        }
    }
}

// MARK: - Drawing I/O

nonisolated enum DrawingIO {
    static func load(_ url: URL) -> PKDrawing? {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return nil }
        return try? PKDrawing(data: data)
    }

    static func loadAll(pageIDs: [UUID], files: NotebookFiles) -> [UUID: PKDrawing] {
        var result: [UUID: PKDrawing] = [:]
        for id in pageIDs {
            result[id] = load(files.drawingURL(id)) ?? PKDrawing()
        }
        return result
    }

    /// Writes (or deletes, for empty drawings) the file for each page.
    static func write(_ drawings: [UUID: Data], files: NotebookFiles) {
        let fm = FileManager.default
        try? fm.createDirectory(at: files.drawingsDirectory, withIntermediateDirectories: true)
        for (id, data) in drawings {
            let url = files.drawingURL(id)
            if data.isEmpty {
                try? fm.removeItem(at: url)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - Importers

nonisolated enum Importer {
    /// Keeps imported pages in a size range where default pen widths feel right.
    static func normalizedPageSize(_ size: CGSize) -> CGSize {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return PageFormat.a4.portraitSize }
        var scale: CGFloat = 1
        if longest > 1300 { scale = 1190 / longest }
        if longest < 480 { scale = 600 / longest }
        return CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
    }

    /// Builds pages for every page of the PDF stored at `url` (already inside the notebook's assets).
    static func pdfPages(at url: URL, file: String, paper: PaperStyle = .white) throws -> [NotebookPage] {
        guard let document = PDFDocument(url: url) else { throw CarnetsError.unreadablePDF }
        if document.isLocked { throw CarnetsError.lockedPDF }
        var pages: [NotebookPage] = []
        for index in 0..<document.pageCount {
            guard let pdfPage = document.page(at: index) else { continue }
            let box = pdfPage.bounds(for: .cropBox)
            let rotation = ((pdfPage.rotation % 360) + 360) % 360
            let displayed = (rotation == 90 || rotation == 270)
                ? CGSize(width: box.height, height: box.width)
                : box.size
            var page = NotebookPage(size: normalizedPageSize(displayed),
                                    background: .pdf(file: file, index: index),
                                    paper: paper)
            page.sourceText = pdfPage.string ?? ""
            pages.append(page)
        }
        if pages.isEmpty { throw CarnetsError.emptyImport }
        return pages
    }

    /// Copies `source` into the notebook's assets and returns the pages it contains.
    static func importPDF(from source: URL, into files: NotebookFiles) throws -> [NotebookPage] {
        files.createDirectories()
        let name = "pdf-\(UUID().uuidString.prefix(8)).pdf"
        let destination = files.assetURL(name)
        try FileManager.default.copyItem(at: source, to: destination)
        do {
            return try pdfPages(at: destination, file: name)
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    /// Writes each image into the notebook's assets and returns one page per image.
    static func imagePages(_ images: [UIImage], into files: NotebookFiles) -> [NotebookPage] {
        files.createDirectories()
        var pages: [NotebookPage] = []
        for image in images {
            guard let stored = storeImage(image, in: files, maxPixel: 2400) else { continue }
            let (name, pixelSize) = stored
            let landscape = pixelSize.width > pixelSize.height
            let base = landscape ? PageFormat.a4.portraitSize.height : PageFormat.a4.portraitSize.width
            let size = CGSize(width: base, height: (base * pixelSize.height / max(pixelSize.width, 1)).rounded())
            pages.append(NotebookPage(size: size, background: .image(file: name), paper: .white))
        }
        return pages
    }

    /// Downscales and stores an image in the assets folder. Returns file name and pixel size.
    static func storeImage(_ image: UIImage, in files: NotebookFiles, maxPixel: CGFloat) -> (String, CGSize)? {
        files.createDirectories()
        let normalized = downscaled(image, maxPixel: maxPixel)
        let alpha = hasAlpha(normalized)
        let name = "img-\(UUID().uuidString.prefix(8)).\(alpha ? "png" : "jpg")"
        let data = alpha ? normalized.pngData() : normalized.jpegData(compressionQuality: 0.86)
        guard let data, (try? data.write(to: files.assetURL(name), options: .atomic)) != nil else { return nil }
        let px = CGSize(width: normalized.size.width * normalized.scale, height: normalized.size.height * normalized.scale)
        return (name, px)
    }

    static func downscaled(_ image: UIImage, maxPixel: CGFloat) -> UIImage {
        let px = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(px.width, px.height)
        let factor = longest > maxPixel ? maxPixel / longest : 1
        let target = CGSize(width: max(1, (px.width * factor).rounded()), height: max(1, (px.height * factor).rounded()))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = !hasAlpha(image)
        // Redrawing also bakes in the EXIF orientation of photos.
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    static func hasAlpha(_ image: UIImage) -> Bool {
        guard let info = image.cgImage?.alphaInfo else { return false }
        switch info {
        case .first, .last, .premultipliedFirst, .premultipliedLast: return true
        default: return false
        }
    }
}
