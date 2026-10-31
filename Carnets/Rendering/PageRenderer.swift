import UIKit
import PencilKit

// MARK: - PageRenderer
// Stateless, thread-safe drawing of pages. Everything works in *page coordinates*
// (points, origin top-left) on a UIKit-style (flipped) CGContext, so the same code
// draws the editor backgrounds, thumbnails and exported PDFs.

nonisolated enum PageRenderer {
    static let mm: CGFloat = 72.0 / 25.4

    // MARK: Background (paper + template / PDF / image)

    static func drawBackground(_ page: NotebookPage, files: NotebookFiles, in ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(page.paper.fill.cgColor)
        ctx.fill(page.bounds)
        switch page.background {
        case .template(let template):
            drawTemplate(template, paper: page.paper, size: page.size, in: ctx)
        case .pdf(let file, let index):
            drawPDFPage(url: files.assetURL(file), index: index, size: page.size, in: ctx)
        case .image(let file):
            if let image = ImageCache.shared.image(at: files.assetURL(file)) {
                drawUIImage(image, in: aspectFit(image.size, in: page.bounds), ctx: ctx)
            }
        }
        ctx.restoreGState()
    }

    // MARK: Templates

    /// `lineScale` thickens rules for small previews, where 0.6 pt lines would vanish.
    static func drawTemplate(_ template: PageTemplate, paper: PaperStyle, size: CGSize, in ctx: CGContext,
                             lineScale: CGFloat = 1) {
        let w = size.width, h = size.height
        let thin: CGFloat = 0.6 * lineScale, strong: CGFloat = 0.9 * lineScale
        ctx.saveGState()
        ctx.setLineCap(.butt)

        switch template {
        case .blank:
            break

        case .lined, .narrowLined:
            let spacing = (template == .lined ? 8.0 : 6.0) * mm
            let top = max(spacing * 3, h * 0.09)
            var y = top
            var path = CGMutablePath()
            while y <= h - spacing * 0.8 {
                path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y))
                y += spacing
            }
            stroke(path, color: paper.line, width: thin, ctx: ctx)
            path = CGMutablePath()
            let marginX = (w * 0.12).rounded()
            path.move(to: CGPoint(x: marginX, y: 0)); path.addLine(to: CGPoint(x: marginX, y: h))
            stroke(path, color: paper.margin, width: thin, ctx: ctx)

        case .seyes:
            let big = 8 * mm, small = 2 * mm
            let thinColor = paper.isDark ? RGBA(1, 1, 1, 0.12) : RGBA(0.56, 0.56, 0.86, 0.36)
            let strongColor = paper.isDark ? RGBA(1, 1, 1, 0.26) : RGBA(0.42, 0.42, 0.80, 0.62)
            let top = big * 2
            let bottom = h - big
            let thinPath = CGMutablePath(), strongPath = CGMutablePath()
            var row = 0
            var y = top
            while y <= bottom + 0.01 {
                let target = row % 4 == 0 ? strongPath : thinPath
                target.move(to: CGPoint(x: 0, y: y)); target.addLine(to: CGPoint(x: w, y: y))
                y += small; row += 1
            }
            var x = big
            while x < w {
                thinPath.move(to: CGPoint(x: x, y: top)); thinPath.addLine(to: CGPoint(x: x, y: bottom))
                x += big
            }
            stroke(thinPath, color: thinColor, width: thin, ctx: ctx)
            stroke(strongPath, color: strongColor, width: thin, ctx: ctx)
            let margin = CGMutablePath()
            let marginX = big * 4 + big * 0.5
            margin.move(to: CGPoint(x: marginX, y: 0)); margin.addLine(to: CGPoint(x: marginX, y: h))
            stroke(margin, color: paper.margin, width: strong, ctx: ctx)

        case .grid, .largeGrid:
            let step = (template == .grid ? 5.0 : 10.0) * mm
            let path = CGMutablePath()
            var x = (w.truncatingRemainder(dividingBy: step)) / 2
            while x <= w { path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: h)); x += step }
            var y = (h.truncatingRemainder(dividingBy: step)) / 2
            while y <= h { path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: w, y: y)); y += step }
            stroke(path, color: template == .grid ? paper.line : paper.line.alpha(paper.line.a * 0.9), width: thin, ctx: ctx)

        case .dots:
            let step = 5 * mm
            let radius: CGFloat = 0.75 * lineScale
            ctx.setFillColor(paper.line.alpha(min(1, paper.line.a * 1.7)).cgColor)
            var y = (h.truncatingRemainder(dividingBy: step)) / 2
            while y <= h {
                var x = (w.truncatingRemainder(dividingBy: step)) / 2
                while x <= w {
                    ctx.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += step
                }
                y += step
            }
            ctx.fillPath()

        case .cornell:
            let spacing = 7 * mm
            let titleBottom = (h * 0.11).rounded()
            let summaryTop = (h * 0.80).rounded()
            let cueX = (w * 0.30).rounded()
            let lines = CGMutablePath()
            var y = titleBottom + spacing
            while y < summaryTop - 2 { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: w, y: y)); y += spacing }
            y = summaryTop + spacing
            while y < h - spacing * 0.5 { lines.move(to: CGPoint(x: 0, y: y)); lines.addLine(to: CGPoint(x: w, y: y)); y += spacing }
            stroke(lines, color: paper.line, width: thin, ctx: ctx)
            let frame = CGMutablePath()
            frame.move(to: CGPoint(x: 0, y: titleBottom)); frame.addLine(to: CGPoint(x: w, y: titleBottom))
            frame.move(to: CGPoint(x: 0, y: summaryTop)); frame.addLine(to: CGPoint(x: w, y: summaryTop))
            frame.move(to: CGPoint(x: cueX, y: titleBottom)); frame.addLine(to: CGPoint(x: cueX, y: summaryTop))
            stroke(frame, color: paper.strongLine, width: strong * 1.4, ctx: ctx)

        case .checklist:
            let spacing = 9 * mm
            let box = 4 * mm
            let left = 12 * mm
            let lines = CGMutablePath()
            let boxes = CGMutablePath()
            var y = max(25 * mm, h * 0.08)
            while y <= h - spacing * 0.8 {
                boxes.addRoundedRect(in: CGRect(x: left, y: y - box - 1.5, width: box, height: box),
                                     cornerWidth: 1.2, cornerHeight: 1.2)
                lines.move(to: CGPoint(x: left + box + 3 * mm, y: y)); lines.addLine(to: CGPoint(x: w - left, y: y))
                y += spacing
            }
            stroke(lines, color: paper.line, width: thin, ctx: ctx)
            stroke(boxes, color: paper.strongLine, width: strong, ctx: ctx)

        case .music:
            let gap = 2.1 * mm
            let staffSpacing = 19 * mm
            let side = 14 * mm
            let staves = CGMutablePath()
            var top = 18 * mm
            while top + gap * 4 <= h - 12 * mm {
                for i in 0..<5 {
                    let y = top + CGFloat(i) * gap
                    staves.move(to: CGPoint(x: side, y: y)); staves.addLine(to: CGPoint(x: w - side, y: y))
                }
                staves.move(to: CGPoint(x: side, y: top)); staves.addLine(to: CGPoint(x: side, y: top + gap * 4))
                staves.move(to: CGPoint(x: w - side, y: top)); staves.addLine(to: CGPoint(x: w - side, y: top + gap * 4))
                top += staffSpacing
            }
            stroke(staves, color: paper.strongLine, width: 0.7 * lineScale, ctx: ctx)
        }
        ctx.restoreGState()
    }

    private static func stroke(_ path: CGPath, color: RGBA, width: CGFloat, ctx: CGContext) {
        ctx.addPath(path)
        ctx.setStrokeColor(color.cgColor)
        ctx.setLineWidth(width)
        ctx.strokePath()
    }

    // MARK: PDF pages

    static func drawPDFPage(url: URL, index: Int, size: CGSize, in ctx: CGContext) {
        PDFCache.shared.withPage(url: url, index: index) { pdfPage in
            let box = pdfPage.getBoxRect(.cropBox)
            guard box.width > 0, box.height > 0 else { return }
            let angle = ((Int(pdfPage.rotationAngle) % 360) + 360) % 360
            let rotated = (angle == 90 || angle == 270)
                ? CGSize(width: box.height, height: box.width)
                : box.size

            ctx.saveGState()
            ctx.clip(to: CGRect(origin: .zero, size: size))
            // Page coordinates (y down) -> PDF coordinates (y up), scaled to the page.
            ctx.translateBy(x: 0, y: size.height)
            ctx.scaleBy(x: size.width / rotated.width, y: -size.height / rotated.height)
            switch angle {
            case 90:
                ctx.translateBy(x: 0, y: rotated.height)
                ctx.rotate(by: -.pi / 2)
            case 180:
                ctx.translateBy(x: rotated.width, y: rotated.height)
                ctx.rotate(by: .pi)
            case 270:
                ctx.translateBy(x: rotated.width, y: 0)
                ctx.rotate(by: .pi / 2)
            default:
                break
            }
            ctx.translateBy(x: -box.minX, y: -box.minY)
            ctx.clip(to: box)
            ctx.interpolationQuality = .high
            ctx.setRenderingIntent(.defaultIntent)
            ctx.drawPDFPage(pdfPage)
            ctx.restoreGState()
        }
    }

    // MARK: Elements

    static func drawElements(_ elements: [PageElement], files: NotebookFiles, in ctx: CGContext) {
        guard !elements.isEmpty else { return }
        UIGraphicsPushContext(ctx)
        for element in elements {
            switch element.kind {
            case .image:
                if let file = element.file, let image = ImageCache.shared.image(at: files.assetURL(file)) {
                    image.draw(in: element.frame)
                }
            case .text:
                NSAttributedString(string: element.text, attributes: textAttributes(for: element))
                    .draw(with: element.frame, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }
        }
        UIGraphicsPopContext()
    }

    static func font(size: CGFloat, style: TextFontStyle) -> UIFont {
        let base = UIFont.systemFont(ofSize: size)
        let design: UIFontDescriptor.SystemDesign
        switch style {
        case .sans:    design = .default
        case .serif:   design = .serif
        case .rounded: design = .rounded
        case .mono:    design = .monospaced
        }
        guard let descriptor = base.fontDescriptor.withDesign(design) else { return base }
        return UIFont(descriptor: descriptor, size: size)
    }

    static func textAttributes(for element: PageElement) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 1.08
        let color = RGBA(hex: element.colorHex) ?? RGBA(0.11, 0.11, 0.12)
        return [
            .font: font(size: CGFloat(element.fontSize), style: element.fontStyle),
            .foregroundColor: UIColor(red: color.r, green: color.g, blue: color.b, alpha: color.a),
            .paragraphStyle: paragraph,
        ]
    }

    /// Height needed to show `text` at `width` with the element's typography.
    static func textHeight(_ text: String, width: CGFloat, element: PageElement) -> CGFloat {
        let display = text.isEmpty ? " " : text
        let rect = NSAttributedString(string: display, attributes: textAttributes(for: element))
            .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                          options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        return ceil(rect.height) + 4
    }

    // MARK: Ink

    static func drawInk(_ drawing: PKDrawing, region: CGRect, scale: CGFloat, in ctx: CGContext) {
        guard !drawing.strokes.isEmpty, drawing.bounds.intersects(region) else { return }
        var image: UIImage?
        // Always render ink with light appearance: colours are stored exactly as chosen.
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: region, scale: scale)
        }
        guard let image else { return }
        drawUIImage(image, in: region, ctx: ctx)
    }

    // MARK: Composite renders

    /// Background only (no elements or ink) for `region` of the page — used by the editor.
    static func renderBackground(page: NotebookPage, files: NotebookFiles, region: CGRect, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: region.size, format: format).image { context in
            let ctx = context.cgContext
            ctx.translateBy(x: -region.minX, y: -region.minY)
            drawBackground(page, files: files, in: ctx)
        }
    }

    /// A complete page (background, elements, ink) as an image.
    static func renderPage(page: NotebookPage, files: NotebookFiles, drawing: PKDrawing?, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: page.size, format: format).image { context in
            let ctx = context.cgContext
            drawBackground(page, files: files, in: ctx)
            drawElements(page.elements, files: files, in: ctx)
            if let ink = drawing ?? DrawingIO.load(files.drawingURL(page.id)) {
                drawInk(ink, region: page.bounds, scale: scale, in: ctx)
            }
        }
    }

    static func renderThumbnail(page: NotebookPage, files: NotebookFiles, drawing: PKDrawing?, maxPixel: CGFloat) -> UIImage {
        let scale = max(0.05, maxPixel / CGFloat(max(page.width, page.height)))
        return renderPage(page: page, files: files, drawing: drawing, scale: scale)
    }

    /// Writes the whole notebook as a PDF. Paper, templates and PDF backgrounds stay vector;
    /// ink is embedded at 3× resolution (≈ 216 dpi).
    static func exportPDF(notebook: Notebook, files: NotebookFiles, drawings: [UUID: PKDrawing]?,
                          pageIndices: [Int]? = nil, to url: URL) throws {
        let indices = pageIndices ?? Array(notebook.pages.indices)
        let pages = indices.compactMap { notebook.pages.indices.contains($0) ? notebook.pages[$0] : nil }
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [
            kCGPDFContextTitle as String: notebook.title,
            kCGPDFContextCreator as String: "Carnets",
        ]
        let firstBounds = pages.first?.bounds ?? CGRect(origin: .zero, size: PageFormat.a4.portraitSize)
        let renderer = UIGraphicsPDFRenderer(bounds: firstBounds, format: format)
        try renderer.writePDF(to: url) { context in
            for page in pages {
                context.beginPage(withBounds: page.bounds, pageInfo: [:])
                let ctx = context.cgContext
                drawBackground(page, files: files, in: ctx)
                drawElements(page.elements, files: files, in: ctx)
                if let ink = drawings?[page.id] ?? DrawingIO.load(files.drawingURL(page.id)) {
                    drawInk(ink, region: page.bounds, scale: 3, in: ctx)
                }
            }
        }
    }

    // MARK: Helpers

    static func aspectFit(_ size: CGSize, in rect: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return rect }
        let s = min(rect.width / size.width, rect.height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }

    private static func drawUIImage(_ image: UIImage, in rect: CGRect, ctx: CGContext) {
        UIGraphicsPushContext(ctx)
        image.draw(in: rect)
        UIGraphicsPopContext()
    }

    /// A file-system friendly name for exports.
    static func exportFileName(_ title: String, suffix: String = "", ext: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        let cleaned = title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? "Carnet" : cleaned
        return base + suffix + "." + ext
    }
}

// MARK: - Caches (thread-safe)

nonisolated final class PDFCache: @unchecked Sendable {
    static let shared = PDFCache()

    private let lock = NSLock()
    private var documents: [URL: CGPDFDocument] = [:]
    private var order: [URL] = []

    /// Runs `body` with the requested page (0-based). PDF drawing is serialised by the lock.
    func withPage(url: URL, index: Int, _ body: (CGPDFPage) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        let document: CGPDFDocument
        if let cached = documents[url] {
            document = cached
        } else {
            guard let opened = CGPDFDocument(url as CFURL) else { return }
            documents[url] = opened
            order.append(url)
            if order.count > 6 {
                let evicted = order.removeFirst()
                documents[evicted] = nil
            }
            document = opened
        }
        guard let page = document.page(at: index + 1) else { return }
        body(page)
    }
}

nonisolated final class ImageCache: @unchecked Sendable {
    static let shared = ImageCache()

    private let cache: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.totalCostLimit = 160 * 1024 * 1024
        return cache
    }()

    func image(at url: URL) -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
        cache.setObject(image, forKey: url as NSURL, cost: cost)
        return image
    }
}
