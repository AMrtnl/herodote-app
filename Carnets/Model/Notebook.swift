import Foundation
import CoreGraphics

// MARK: - RGBA colour (UI-framework independent, Codable)

nonisolated struct RGBA: Codable, Hashable, Sendable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    /// Accepts "#RRGGBB" or "#RRGGBBAA".
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        if s.count == 6 {
            r = Double((v >> 16) & 0xFF) / 255
            g = Double((v >> 8) & 0xFF) / 255
            b = Double(v & 0xFF) / 255
            a = 1
        } else {
            r = Double((v >> 24) & 0xFF) / 255
            g = Double((v >> 16) & 0xFF) / 255
            b = Double((v >> 8) & 0xFF) / 255
            a = Double(v & 0xFF) / 255
        }
    }

    var hex: String {
        func c(_ x: Double) -> Int { Int((max(0, min(1, x)) * 255).rounded()) }
        if a >= 0.999 { return String(format: "#%02X%02X%02X", c(r), c(g), c(b)) }
        return String(format: "#%02X%02X%02X%02X", c(r), c(g), c(b), c(a))
    }

    var cgColor: CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }

    func alpha(_ value: Double) -> RGBA { RGBA(r, g, b, value) }

    /// Perceived luminance (0 = black, 1 = white).
    var luminance: Double { 0.299 * r + 0.587 * g + 0.114 * b }
}

// MARK: - Paper templates

nonisolated enum PageTemplate: String, Codable, CaseIterable, Identifiable, Sendable {
    case blank, lined, narrowLined, seyes, grid, largeGrid, dots, cornell, checklist, music

    var id: String { rawValue }

    var label: String {
        switch self {
        case .blank:       return "Vierge"
        case .lined:       return "Ligné"
        case .narrowLined: return "Ligné étroit"
        case .seyes:       return "Seyès"
        case .grid:        return "Quadrillé 5 mm"
        case .largeGrid:   return "Quadrillé 1 cm"
        case .dots:        return "Pointillé"
        case .cornell:     return "Cornell"
        case .checklist:   return "Liste de tâches"
        case .music:       return "Partition"
        }
    }
}

// MARK: - Paper colours

nonisolated enum PaperStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case white, ivory, eInk, yellow, slate, night

    var id: String { rawValue }

    var label: String {
        switch self {
        case .white:  return "Blanc"
        case .ivory:  return "Ivoire"
        case .eInk:   return "Encre numérique"
        case .yellow: return "Jaune"
        case .slate:  return "Ardoise"
        case .night:  return "Nuit"
        }
    }

    var fill: RGBA {
        switch self {
        case .white:  return RGBA(1, 1, 1)
        case .ivory:  return RGBA(0.988, 0.969, 0.925)
        case .eInk:   return RGBA(0.925, 0.922, 0.906)
        case .yellow: return RGBA(1.0, 0.965, 0.760)
        case .slate:  return RGBA(0.278, 0.314, 0.353)
        case .night:  return RGBA(0.114, 0.114, 0.125)
        }
    }

    var isDark: Bool { self == .slate || self == .night }

    /// Thin template lines.
    var line: RGBA {
        switch self {
        case .white, .ivory: return RGBA(0.52, 0.60, 0.74, 0.42)
        case .eInk:          return RGBA(0.45, 0.45, 0.45, 0.35)
        case .yellow:        return RGBA(0.42, 0.55, 0.72, 0.45)
        case .slate, .night: return RGBA(1, 1, 1, 0.16)
        }
    }

    /// Emphasised template lines (Seyès main lines, staff lines…).
    var strongLine: RGBA {
        switch self {
        case .white, .ivory, .yellow: return RGBA(0.38, 0.45, 0.70, 0.62)
        case .eInk:                   return RGBA(0.30, 0.30, 0.30, 0.55)
        case .slate, .night:          return RGBA(1, 1, 1, 0.30)
        }
    }

    /// Margin rule.
    var margin: RGBA {
        isDark ? RGBA(1, 0.55, 0.55, 0.40) : RGBA(0.86, 0.33, 0.33, 0.55)
    }
}

// MARK: - Page formats

nonisolated enum PageFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case a4, a5, letter, tablet, square

    var id: String { rawValue }

    var label: String {
        switch self {
        case .a4:     return "A4"
        case .a5:     return "A5"
        case .letter: return "Letter"
        case .tablet: return "Tablette 3:4"
        case .square: return "Carré"
        }
    }

    /// Portrait size in PDF points (1/72 in).
    var portraitSize: CGSize {
        switch self {
        case .a4:     return CGSize(width: 595.28, height: 841.89)
        case .a5:     return CGSize(width: 419.53, height: 595.28)
        case .letter: return CGSize(width: 612, height: 792)
        case .tablet: return CGSize(width: 540, height: 720)
        case .square: return CGSize(width: 600, height: 600)
        }
    }

    func size(landscape: Bool) -> CGSize {
        let s = portraitSize
        return landscape ? CGSize(width: s.height, height: s.width) : s
    }
}

// MARK: - Covers

nonisolated enum CoverStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case graphite, ink, ocean, forest, sage, terracotta, mustard, plum, rose, sand

    var id: String { rawValue }

    var label: String {
        switch self {
        case .graphite:   return "Graphite"
        case .ink:        return "Encre"
        case .ocean:      return "Océan"
        case .forest:     return "Forêt"
        case .sage:       return "Sauge"
        case .terracotta: return "Terre cuite"
        case .mustard:    return "Moutarde"
        case .plum:       return "Prune"
        case .rose:       return "Rose"
        case .sand:       return "Sable"
        }
    }

    var base: RGBA {
        switch self {
        case .graphite:   return RGBA(0.20, 0.21, 0.23)
        case .ink:        return RGBA(0.13, 0.20, 0.42)
        case .ocean:      return RGBA(0.09, 0.42, 0.55)
        case .forest:     return RGBA(0.13, 0.33, 0.24)
        case .sage:       return RGBA(0.53, 0.62, 0.52)
        case .terracotta: return RGBA(0.75, 0.36, 0.24)
        case .mustard:    return RGBA(0.86, 0.66, 0.22)
        case .plum:       return RGBA(0.40, 0.20, 0.38)
        case .rose:       return RGBA(0.89, 0.60, 0.62)
        case .sand:       return RGBA(0.84, 0.77, 0.65)
        }
    }

    /// Lighter tone used for the label band and spine.
    var accent: RGBA {
        let b = base
        return RGBA(b.r + (1 - b.r) * 0.35, b.g + (1 - b.g) * 0.35, b.b + (1 - b.b) * 0.35)
    }

    var isLight: Bool { base.luminance > 0.62 }
}

// MARK: - Page background

nonisolated enum PageBackground: Codable, Equatable, Sendable {
    /// A generated paper template.
    case template(PageTemplate)
    /// Page `index` of the PDF stored as `file` inside the notebook package.
    case pdf(file: String, index: Int)
    /// A raster image (photo, scan) stored as `file` inside the notebook package.
    case image(file: String)

    var template: PageTemplate? {
        if case .template(let t) = self { return t }
        return nil
    }

    var isTemplate: Bool { template != nil }
}

// MARK: - Page elements (images & text boxes)

nonisolated enum PageElementKind: String, Codable, Sendable {
    case image, text
}

nonisolated enum TextFontStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case sans, serif, rounded, mono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sans:    return "Sans"
        case .serif:   return "Serif"
        case .rounded: return "Arrondie"
        case .mono:    return "Mono"
        }
    }
}

nonisolated struct PageElement: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var kind: PageElementKind
    /// Frame in page coordinates (points, origin top-left).
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    /// Image file inside the notebook's `assets` folder.
    var file: String? = nil
    var text: String = ""
    var fontSize: Double = 18
    var fontStyle: TextFontStyle = .sans
    var colorHex: String = "#1C1C1E"

    var frame: CGRect {
        get { CGRect(x: x, y: y, width: width, height: height) }
        set { x = newValue.minX; y = newValue.minY; width = newValue.width; height = newValue.height }
    }

    static func makeImage(file: String, frame: CGRect) -> PageElement {
        PageElement(kind: .image, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height, file: file)
    }

    static func makeText(_ text: String, frame: CGRect, fontSize: Double, style: TextFontStyle, colorHex: String) -> PageElement {
        PageElement(kind: .text, x: frame.minX, y: frame.minY, width: frame.width, height: frame.height,
                    text: text, fontSize: fontSize, fontStyle: style, colorHex: colorHex)
    }
}

// MARK: - Page

nonisolated struct NotebookPage: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var width: Double
    var height: Double
    var background: PageBackground
    var paper: PaperStyle
    var elements: [PageElement] = []
    var isBookmarked: Bool = false
    /// Best reading of the handwriting on the page (for "copy as text").
    var recognizedText: String = ""
    /// All plausible readings of the handwriting (used for search).
    var searchableText: String = ""
    /// Text extracted from the page's PDF background, if any.
    var sourceText: String = ""
    var recognitionVersion: Int = 0
    /// Bumped on every visual change; drives thumbnail invalidation and re-indexing.
    var revision: Int = 0

    var size: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    init(size: CGSize, background: PageBackground, paper: PaperStyle) {
        self.width = Double(size.width)
        self.height = Double(size.height)
        self.background = background
        self.paper = paper
    }

    /// A blank copy with a new identity (same size, paper and template; no ink or elements).
    func emptyCopy() -> NotebookPage {
        let bg: PageBackground = background.isTemplate ? background : .template(.blank)
        return NotebookPage(size: size, background: bg, paper: paper)
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, width, height, background, paper, elements, isBookmarked
        case recognizedText, searchableText, sourceText, recognitionVersion, revision
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id                 = c.value(.id, default: UUID())
        width              = c.value(.width, default: 595.28)
        height             = c.value(.height, default: 841.89)
        background         = c.value(.background, default: .template(.blank))
        paper              = c.value(.paper, default: .white)
        elements           = c.value(.elements, default: [])
        isBookmarked       = c.value(.isBookmarked, default: false)
        recognizedText     = c.value(.recognizedText, default: "")
        searchableText     = c.value(.searchableText, default: "")
        sourceText         = c.value(.sourceText, default: "")
        recognitionVersion = c.value(.recognitionVersion, default: 0)
        revision           = c.value(.revision, default: 0)
    }
}

// MARK: - Where a notebook comes from

nonisolated enum NotebookOrigin: String, Codable, Sendable {
    case carnets, goodNotes, pdf, scan, photos

    var label: String {
        switch self {
        case .carnets:   return "Carnets"
        case .goodNotes: return "GoodNotes"
        case .pdf:       return "PDF importé"
        case .scan:      return "Numérisation"
        case .photos:    return "Photos"
        }
    }
}

nonisolated struct NotebookSource: Codable, Equatable, Sendable {
    var origin: NotebookOrigin
    /// File name of the imported document, e.g. "Philosophie L2.pdf".
    var originalName: String?
    /// Asset (inside the notebook's `assets` folder) holding the original document.
    var originalFile: String?
    var importedAt: Date = .now
    /// Last time a newer export replaced the pages.
    var updatedAt: Date?

    init(origin: NotebookOrigin, originalName: String? = nil, originalFile: String? = nil) {
        self.origin = origin
        self.originalName = originalName
        self.originalFile = originalFile
    }

    nonisolated enum CodingKeys: String, CodingKey {
        case origin, originalName, originalFile, importedAt, updatedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        origin = c.value(.origin, default: .pdf)
        originalName = c.value(.originalName, default: Optional<String>.none)
        originalFile = c.value(.originalFile, default: Optional<String>.none)
        importedAt = c.value(.importedAt, default: Date.now)
        updatedAt = c.value(.updatedAt, default: Optional<Date>.none)
    }
}

// MARK: - Notebook

nonisolated struct Notebook: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var title: String
    /// `nil` = no cover: the library shows the first page instead (used for imported PDFs).
    var cover: CoverStyle? = .ink
    var folderID: UUID? = nil
    var isFavorite: Bool = false
    var createdAt: Date = .now
    var modifiedAt: Date = .now
    var openedAt: Date? = nil
    var pages: [NotebookPage] = []
    var defaultTemplate: PageTemplate = .lined
    var defaultPaper: PaperStyle = .white
    var defaultFormat: PageFormat = .a4
    var landscape: Bool = false
    var lastPageIndex: Int = 0
    /// `nil` for notebooks created in Carnets.
    var source: NotebookSource? = nil

    var origin: NotebookOrigin { source?.origin ?? .carnets }

    init(title: String, cover: CoverStyle?, template: PageTemplate, paper: PaperStyle,
         format: PageFormat, landscape: Bool, folderID: UUID?) {
        self.title = title
        self.cover = cover
        self.defaultTemplate = template
        self.defaultPaper = paper
        self.defaultFormat = format
        self.landscape = landscape
        self.folderID = folderID
    }

    /// A new blank page using the notebook's defaults.
    func makeDefaultPage(template: PageTemplate? = nil) -> NotebookPage {
        NotebookPage(size: defaultFormat.size(landscape: landscape),
                     background: .template(template ?? defaultTemplate),
                     paper: defaultPaper)
    }

    var pageCount: Int { pages.count }

    nonisolated enum CodingKeys: String, CodingKey {
        case id, title, cover, folderID, isFavorite, createdAt, modifiedAt, openedAt, pages
        case defaultTemplate, defaultPaper, defaultFormat, landscape, lastPageIndex, source
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id              = c.value(.id, default: UUID())
        title           = c.value(.title, default: "Carnet")
        cover           = c.value(.cover, default: Optional<CoverStyle>.none)
        folderID        = c.value(.folderID, default: Optional<UUID>.none)
        isFavorite      = c.value(.isFavorite, default: false)
        createdAt       = c.value(.createdAt, default: Date.now)
        modifiedAt      = c.value(.modifiedAt, default: Date.now)
        openedAt        = c.value(.openedAt, default: Optional<Date>.none)
        pages           = c.value(.pages, default: [])
        defaultTemplate = c.value(.defaultTemplate, default: .lined)
        defaultPaper    = c.value(.defaultPaper, default: .white)
        defaultFormat   = c.value(.defaultFormat, default: .a4)
        landscape       = c.value(.landscape, default: false)
        lastPageIndex   = c.value(.lastPageIndex, default: 0)
        source          = c.value(.source, default: Optional<NotebookSource>.none)
    }
}

// MARK: - Folder

nonisolated struct Folder: Identifiable, Codable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var createdAt: Date = .now
}

// MARK: - Library index file

nonisolated struct LibraryIndex: Codable, Sendable {
    var folders: [Folder] = []
}

// MARK: - Lenient decoding helper

extension KeyedDecodingContainer {
    /// Decodes `key` if present and valid, otherwise returns `fallback`.
    /// Keeps old files readable when the schema gains new fields.
    nonisolated func value<T: Decodable>(_ key: Key, default fallback: T) -> T {
        guard let decoded = try? decodeIfPresent(T.self, forKey: key) else { return fallback }
        return decoded
    }
}
