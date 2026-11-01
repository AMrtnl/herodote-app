import SwiftUI
import UIKit
import PencilKit
import Observation

// MARK: - Tools

enum EditorTool: String, CaseIterable, Identifiable {
    case pen, pencil, highlighter, eraser, lasso, text, hand, laser

    var id: String { rawValue }

    var label: String {
        switch self {
        case .pen:         return "Stylo"
        case .pencil:      return "Crayon"
        case .highlighter: return "Surligneur"
        case .eraser:      return "Gomme"
        case .lasso:       return "Lasso"
        case .text:        return "Texte"
        case .hand:        return "Sélection"
        case .laser:       return "Pointeur laser"
        }
    }

    var symbol: String {
        switch self {
        case .pen:         return "pencil.tip"
        case .pencil:      return "pencil"
        case .highlighter: return "highlighter"
        case .eraser:      return "eraser"
        case .lasso:       return "lasso"
        case .text:        return "character.textbox"
        case .hand:        return "hand.point.up.left"
        case .laser:       return "laser.burst"
        }
    }

    /// Tools that lay down ink.
    var isInk: Bool { self == .pen || self == .pencil || self == .highlighter }

    /// Tools that use a colour.
    var usesColor: Bool { isInk }

    /// Tools offered when the notebook is read-only (iPhone, Mac).
    static let readerTools: [EditorTool] = [.hand, .laser]
}

/// Everything the canvas needs to configure PencilKit. Value type so SwiftUI can diff it.
struct ToolConfiguration: Equatable {
    var tool: EditorTool
    var inkType: PKInkingTool.InkType
    var colorHex: String
    var width: CGFloat
    var eraserMode: EraserMode
    var eraserWidth: CGFloat
    var ruler: Bool
    var fingerDrawing: Bool
    var readOnly: Bool
}

enum ToolPresets {
    static let penColors = ["#1C1C1E", "#1F4FD8", "#D7263D", "#1B9E5A", "#7B3FE4"]
    static let penColorsOnDark = ["#F5F5F7", "#8AB4FF", "#FF7A85", "#6EE7A8", "#C9A7FF"]
    static let highlighterColors = ["#FFE14D", "#7DE38A", "#FF8FB1", "#7CC4FF", "#FFB547"]

    static func inkType(for tool: EditorTool, penStyle: PenStyle) -> PKInkingTool.InkType {
        switch tool {
        case .pencil:      return .pencil
        case .highlighter: return .marker
        default:
            switch penStyle {
            case .fountain:  return .fountainPen
            case .ballpoint: return .pen
            case .felt:      return .monoline
            case .brush:     return .watercolor
            }
        }
    }

    static func widths(for tool: EditorTool, penStyle: PenStyle) -> [CGFloat] {
        switch tool {
        case .pencil:      return [1.6, 3.0, 6.0]
        case .highlighter: return [9, 15, 24]
        case .eraser:      return [6, 14, 30]
        default:
            switch penStyle {
            case .fountain:  return [1.6, 2.8, 4.6]
            case .ballpoint: return [1.2, 2.0, 3.4]
            case .felt:      return [1.0, 2.0, 3.5]
            case .brush:     return [4, 8, 14]
            }
        }
    }

    static func width(for tool: EditorTool, penStyle: PenStyle, index: Int) -> CGFloat {
        let options = widths(for: tool, penStyle: penStyle)
        let value = options[max(0, min(options.count - 1, index))]
        guard tool.isInk else { return value }
        let range = inkType(for: tool, penStyle: penStyle).validWidthRange
        return min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Presentation payloads

struct SearchHit: Equatable {
    /// Rectangle in canvas (notebook) coordinates.
    var rect: CGRect
    var pageIndex: Int
}

struct TextEditRequest: Identifiable {
    let id = UUID()
    let pageID: UUID
    /// `nil` when creating a new text box.
    let elementID: UUID?
    var element: PageElement
}

struct ConversionResult: Identifiable {
    let id = UUID()
    var text: String
    let strokeIDs: Set<UUID>
    /// Bounds of the converted strokes in canvas coordinates.
    let bounds: CGRect
}

struct PageTitleRequest: Identifiable {
    let id = UUID()
    let pageIndex: Int
    var title: String
}

struct SharedFile: Identifiable {
    let id = UUID()
    let url: URL
}

enum TemplatePickerMode: Equatable {
    case insert(after: Int)
    case change(pageIndex: Int)
}

struct TemplatePickerRequest: Identifiable {
    let id = UUID()
    let mode: TemplatePickerMode
}

// MARK: - EditorModel

@Observable final class EditorModel {
    let notebookID: UUID
    let store: NotebookStore
    let settings: CarnetsSettings
    /// iPhone and Mac: view, search, point and export, but never change the notebook.
    let isReadOnly: Bool

    // Tools
    var tool: EditorTool
    private(set) var previousTool: EditorTool = .pen
    var ruler = false
    /// Snap every stroke to a shape (in addition to "draw and hold").
    var alwaysSnapShapes = false
    var showToolOptions = false

    // Document state (written by the canvas)
    var isLoaded = false
    var currentPageIndex = 0
    var pageCount = 0
    var canUndo = false
    var canRedo = false
    var zoomPercent = 100
    var selectedElementID: UUID?
    var hasStrokeSelection = false

    // Search inside the notebook
    var isSearching = false
    var searchQuery = ""
    var searchHits: [SearchHit] = []
    var currentHit = 0
    var searchRunning = false

    // Presentation
    var focusMode = false
    var showPageNavigator = false
    var templatePicker: TemplatePickerRequest?
    var pageTitleEdit: PageTitleRequest?
    var textEdit: TextEditRequest?
    var conversion: ConversionResult?
    var sharedFile: SharedFile?
    var busyMessage: String?
    var toast: String?
    var errorMessage: String?

    @ObservationIgnored weak var canvas: NotebookCanvasController?
    @ObservationIgnored private var toastTask: Task<Void, Never>?

    init(notebookID: UUID, store: NotebookStore = .shared, settings: CarnetsSettings = .shared) {
        self.notebookID = notebookID
        self.store = store
        self.settings = settings
        self.isReadOnly = store.isReadOnly
        self.tool = store.isReadOnly ? .hand : .pen
    }

    var isHorizontal: Bool { settings.scrollDirection == .horizontal }

    func toggleScrollDirection() {
        settings.scrollDirection = isHorizontal ? .vertical : .horizontal
        settings.save()
        canvas?.applyScrollDirection()
        flash(isHorizontal ? "Pages côte à côte : feuilletez d’un geste" : "Défilement vertical continu")
    }

    var notebook: Notebook? { store.notebook(notebookID) }

    var currentPage: NotebookPage? {
        guard let pages = notebook?.pages, pages.indices.contains(currentPageIndex) else { return nil }
        return pages[currentPageIndex]
    }

    var currentPaperIsDark: Bool { currentPage?.paper.isDark ?? false }

    // MARK: Tool state

    var configuration: ToolConfiguration {
        let t = settings.tools
        return ToolConfiguration(
            tool: tool,
            inkType: ToolPresets.inkType(for: tool, penStyle: t.penStyle),
            colorHex: currentColorHex,
            width: ToolPresets.width(for: tool, penStyle: t.penStyle, index: currentWidthIndex),
            eraserMode: t.eraserMode,
            eraserWidth: ToolPresets.width(for: .eraser, penStyle: t.penStyle, index: t.eraserWidth),
            ruler: ruler,
            fingerDrawing: settings.fingerDrawing,
            readOnly: isReadOnly
        )
    }

    func select(_ newTool: EditorTool) {
        if isReadOnly && !EditorTool.readerTools.contains(newTool) { return }
        if newTool == .laser {
            if tool == .laser {
                tool = isReadOnly ? .hand : (previousTool == .laser ? .pen : previousTool)
                flash("Pointeur laser désactivé")
            } else {
                previousTool = tool
                tool = .laser
                selectedElementID = nil
                flash("Pointeur laser : le trait s’efface tout seul")
            }
            showToolOptions = false
            return
        }
        if newTool == tool {
            showToolOptions.toggle()
            return
        }
        previousTool = tool
        tool = newTool
        showToolOptions = false
        if newTool != .hand { selectedElementID = nil }
    }

    func switchToPreviousTool() {
        if isReadOnly {
            select(.laser)
            return
        }
        let target = previousTool == tool ? .pen : previousTool
        previousTool = tool
        tool = target
    }

    func toggleEraser() {
        if tool == .eraser { switchToPreviousTool() } else { select(.eraser) }
    }

    var palette: [String] {
        switch tool {
        case .highlighter: return ToolPresets.highlighterColors
        default:           return currentPaperIsDark ? ToolPresets.penColorsOnDark : ToolPresets.penColors
        }
    }

    var currentColorHex: String {
        let t = settings.tools
        switch tool {
        case .pencil:      return t.pencilColor
        case .highlighter: return t.highlighterColor
        default:           return t.penColor
        }
    }

    var currentWidthIndex: Int {
        let t = settings.tools
        switch tool {
        case .pencil:      return t.pencilWidth
        case .highlighter: return t.highlighterWidth
        case .eraser:      return t.eraserWidth
        default:           return t.penWidth
        }
    }

    /// The ink tool whose colour the palette edits (text uses the pen colour).
    private var colorTool: EditorTool { tool.isInk ? tool : .pen }

    func setColor(_ hex: String, custom: Bool = false) {
        var t = settings.tools
        switch colorTool {
        case .pencil:      t.pencilColor = hex
        case .highlighter: t.highlighterColor = hex
        default:           t.penColor = hex
        }
        if custom {
            t.customColors.removeAll { $0 == hex }
            t.customColors.insert(hex, at: 0)
            t.customColors = Array(t.customColors.prefix(6))
        }
        settings.tools = t
        settings.save()
        if !tool.isInk && tool != .text { tool = colorTool }
    }

    func setWidthIndex(_ index: Int) {
        var t = settings.tools
        switch tool {
        case .pencil:      t.pencilWidth = index
        case .highlighter: t.highlighterWidth = index
        case .eraser:      t.eraserWidth = index
        default:           t.penWidth = index
        }
        settings.tools = t
        settings.save()
    }

    func setPenStyle(_ style: PenStyle) {
        settings.tools.penStyle = style
        settings.save()
        if tool != .pen { tool = .pen }
    }

    func setEraserMode(_ mode: EraserMode) {
        settings.tools.eraserMode = mode
        settings.save()
    }

    func toggleFingerDrawing() {
        settings.fingerDrawing.toggle()
        settings.save()
        flash(settings.fingerDrawing ? "Dessin au doigt activé" : "Apple Pencil uniquement")
    }

    // MARK: Messages

    func flash(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self?.toast = nil
        }
    }

    // MARK: Search

    func runSearch() {
        let query = searchQuery
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty, let canvas else {
            searchHits = []
            searchRunning = false
            canvas?.showSearchHits([], current: 0)
            return
        }
        searchRunning = true
        Task {
            let hits = await canvas.search(query)
            guard query == self.searchQuery else { return }
            self.searchHits = hits
            self.currentHit = 0
            self.searchRunning = false
            canvas.showSearchHits(hits, current: 0)
        }
    }

    func nextHit(_ delta: Int) {
        guard !searchHits.isEmpty else { return }
        currentHit = (currentHit + delta + searchHits.count) % searchHits.count
        canvas?.showSearchHits(searchHits, current: currentHit)
    }

    func endSearch() {
        isSearching = false
        searchQuery = ""
        searchHits = []
        canvas?.showSearchHits([], current: 0)
    }

    // MARK: Export

    func exportPDF(pageIndices: [Int]? = nil) {
        guard let canvas, let notebook else { return }
        busyMessage = "Exportation du PDF…"
        Task {
            do {
                let url = try await canvas.exportPDF(pageIndices: pageIndices)
                self.sharedFile = SharedFile(url: url)
            } catch {
                self.errorMessage = "L’export de « \(notebook.title) » a échoué : \(error.localizedDescription)"
            }
            self.busyMessage = nil
        }
    }

    func exportCurrentPageImage() {
        guard let canvas else { return }
        busyMessage = "Préparation de l’image…"
        Task {
            if let url = await canvas.exportPageImage(at: currentPageIndex) {
                self.sharedFile = SharedFile(url: url)
            }
            self.busyMessage = nil
        }
    }

    func copyCurrentPageText() {
        guard let canvas else { return }
        busyMessage = "Reconnaissance de l’écriture…"
        Task {
            let text = await canvas.recognizedText(ofPage: currentPageIndex)
            self.busyMessage = nil
            if text.isEmpty {
                self.flash("Aucune écriture reconnue sur cette page")
            } else {
                UIPasteboard.general.string = text
                self.flash("Texte de la page copié")
            }
        }
    }
}
