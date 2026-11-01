import UIKit
import PencilKit
import PDFKit

// MARK: - NotebookCanvasController
//
// One PKCanvasView hosts the whole notebook: pages are stacked vertically (or side by side,
// turned one at a time) in a single "canvas coordinate space" (points, before zoom). Ink is split per page when saved
// and re-composed when the notebook opens, so each page keeps its own drawing file.
//
// Layering inside the canvas (bottom → top):
//   underlay [ page backgrounds | elements (images, text) | search highlights ]
//   PencilKit ink
//   selection overlay

final class NotebookCanvasController: UIViewController, PKCanvasViewDelegate,
                                      UIGestureRecognizerDelegate, UIPencilInteractionDelegate {

    let model: EditorModel
    let canvasView = PKCanvasView()

    private let files: NotebookFiles
    private let history = UndoManager()
    override var undoManager: UndoManager? { history }

    // Pages & layout
    private var pages: [NotebookPage] = []
    private var pageRects: [CGRect] = []
    private var contentWidth: CGFloat = 640
    private var contentHeight: CGFloat = 900
    private let pageGap: CGFloat = 28
    private let margin: CGFloat = 24
    private var fitScale: CGFloat = 0
    private var laidOutWidth: CGFloat = 0
    private var insets = UIEdgeInsets.zero
    private var pendingScrollPage: Int?
    /// Pages side by side, snapping one page at a time.
    private var horizontal = false
    private var isReadOnly: Bool { model.isReadOnly }
    private var laserUndoSuspended = false
    private var dragStartPage = 0

    // Views
    private let underlay = UIView()
    private let pagesContainer = UIView()
    private let elementsContainer = UIView()
    private let highlightsContainer = UIView()
    private let selectionView = SelectionOverlayView(frame: .zero)
    private var pageViews: [UUID: PageBackgroundView] = [:]
    private var elementViews: [UUID: ElementView] = [:]
    private var highlightLayers: [CALayer] = []
    private var hits: [SearchHit] = []
    private var currentHitIndex = 0
    private let backgroundCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 140 * 1024 * 1024
        return cache
    }()

    // Ink bookkeeping
    private var pageDrawings: [UUID: PKDrawing] = [:]
    private var savedData: [UUID: Data] = [:]
    private var savedFingerprints: [UUID: [Double]] = [:]
    private var saveTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var isSettingDrawing = false
    private var strokeCount = 0
    private var isLoaded = false
    private var appliedConfiguration: ToolConfiguration?
    private var recognizer: PKStrokeRecognizer?

    // Gestures
    private let touchObserver = StrokeTouchObserver(target: nil, action: nil)
    private lazy var undoTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleUndoTap(_:)))
        g.numberOfTouchesRequired = 2
        g.delegate = self
        return g
    }()
    private lazy var redoTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleRedoTap(_:)))
        g.numberOfTouchesRequired = 3
        g.delegate = self
        return g
    }()
    private lazy var elementTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleElementTap(_:)))
        g.delegate = self
        return g
    }()
    private lazy var elementDoubleTap: UITapGestureRecognizer = {
        let g = UITapGestureRecognizer(target: self, action: #selector(handleElementDoubleTap(_:)))
        g.numberOfTapsRequired = 2
        g.delegate = self
        return g
    }()
    private lazy var elementPan: UIPanGestureRecognizer = {
        let g = UIPanGestureRecognizer(target: self, action: #selector(handleElementPan(_:)))
        g.maximumNumberOfTouches = 1
        g.delegate = self
        return g
    }()

    private enum DragMode { case move, resize }
    private struct ElementDrag {
        let pageIndex: Int
        let elementID: UUID
        let mode: DragMode
        let original: CGRect
        let originalElements: [PageElement]
    }
    private var drag: ElementDrag?

    // MARK: Lifecycle

    init(model: EditorModel) {
        self.model = model
        self.files = model.store.files(for: model.notebookID)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.09, alpha: 1)
                : UIColor(red: 0.925, green: 0.925, blue: 0.937, alpha: 1)
        }

        canvasView.frame = view.bounds
        canvasView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        canvasView.backgroundColor = .clear
        canvasView.isOpaque = false
        // Ink colours are shown exactly as chosen, whatever the system appearance.
        canvasView.overrideUserInterfaceStyle = .light
        canvasView.contentInsetAdjustmentBehavior = .never
        horizontal = model.isHorizontal
        canvasView.alwaysBounceVertical = !horizontal
        canvasView.alwaysBounceHorizontal = horizontal
        canvasView.showsHorizontalScrollIndicator = false
        canvasView.showsVerticalScrollIndicator = !horizontal
        canvasView.decelerationRate = horizontal ? .fast : .normal
        canvasView.delegate = self
        view.addSubview(canvasView)

        underlay.isUserInteractionEnabled = false
        for container in [pagesContainer, elementsContainer, highlightsContainer] {
            container.isUserInteractionEnabled = false
            container.frame = underlay.bounds
            container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            underlay.addSubview(container)
        }
        canvasView.insertSubview(underlay, at: 0)

        selectionView.isHidden = true
        canvasView.addSubview(selectionView)

        touchObserver.delegate = self
        canvasView.addGestureRecognizer(touchObserver)
        canvasView.addGestureRecognizer(undoTap)
        canvasView.addGestureRecognizer(redoTap)
        canvasView.addGestureRecognizer(elementDoubleTap)
        canvasView.addGestureRecognizer(elementTap)
        elementTap.require(toFail: elementDoubleTap)
        canvasView.addGestureRecognizer(elementPan)
        canvasView.addInteraction(UIPencilInteraction(delegate: self))

        let center = NotificationCenter.default
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup,
                     .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(self, selector: #selector(undoStateChanged(_:)), name: name, object: history)
        }
        center.addObserver(self, selector: #selector(appWillResign(_:)),
                           name: UIApplication.didEnterBackgroundNotification, object: nil)

        apply(model.configuration)
        loadDocument()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard isLoaded, canvasView.bounds.width > 0 else { return }
        if abs(canvasView.bounds.width - laidOutWidth) > 0.5 {
            configureZoom(preserveRelative: fitScale > 0)
            if let page = pendingScrollPage {
                pendingScrollPage = nil
                scrollToPage(page, animated: false)
            }
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        commitInk()
    }

    /// Called when the editor closes.
    func finish() {
        let index = model.currentPageIndex
        if isReadOnly {
            // Readers keep their place on the device; the notebook itself is never written.
            ReadingPositions.set(index, for: model.notebookID)
            return
        }
        commitInk()
        model.store.update(model.notebookID, touch: false) { $0.lastPageIndex = index }
        model.store.flush(model.notebookID)
        model.store.collectGarbage(model.notebookID)
    }

    @objc private func appWillResign(_ note: Notification) {
        commitInk()
        model.store.flushAll()
    }

    // MARK: Loading & layout

    private func loadDocument() {
        reloadPages()
        let ids = pages.map(\.id)
        let files = self.files
        Task { [weak self] in
            let loaded = await Task.detached(priority: .userInitiated) { () -> ([UUID: PKDrawing], [UUID: Data]) in
                let drawings = DrawingIO.loadAll(pageIDs: ids, files: files)
                let data = drawings.mapValues { $0.strokes.isEmpty ? Data() : $0.dataRepresentation() }
                return (drawings, data)
            }.value
            guard let self else { return }
            self.pageDrawings = loaded.0
            self.savedData = loaded.1
            for (id, drawing) in loaded.0 { self.savedFingerprints[id] = Self.fingerprint(drawing) }
            self.isLoaded = true
            let stored = self.model.notebook?.lastPageIndex ?? 0
            let last = self.isReadOnly ? (ReadingPositions.page(for: self.model.notebookID) ?? stored) : stored
            self.rebuild(scrollTo: min(max(last, 0), max(self.pages.count - 1, 0)))
            self.model.isLoaded = true
            if self.pages.contains(where: { $0.recognitionVersion < PKStrokeRecognizer.recognitionVersion }) {
                let stale = self.pages.filter { $0.recognitionVersion < PKStrokeRecognizer.recognitionVersion }.map(\.id)
                HandwritingIndexer.shared.schedule(notebookID: self.model.notebookID, pageIDs: stale, drawings: loaded.0)
            }
        }
    }

    private func reloadPages() {
        pages = model.notebook?.pages ?? []
        if model.pageCount != pages.count { model.pageCount = pages.count }
    }

    private func mutatePages(touch: Bool = true, _ body: (inout [NotebookPage]) -> Void) {
        model.store.update(model.notebookID, touch: touch) { body(&$0.pages) }
        reloadPages()
    }

    private func computeLayout() {
        if horizontal {
            let tallest = pages.map { $0.size.height }.max() ?? PageFormat.a4.portraitSize.height
            var x = margin
            pageRects = pages.map { page in
                let rect = CGRect(x: x, y: margin + (tallest - page.size.height) / 2,
                                  width: page.size.width, height: page.size.height)
                x += page.size.width + pageGap * 2
                return rect
            }
            contentWidth = max(x - pageGap * 2 + margin, margin * 2)
            contentHeight = tallest + margin * 2
            return
        }
        let widest = pages.map { $0.size.width }.max() ?? PageFormat.a4.portraitSize.width
        contentWidth = widest + margin * 2
        var y = margin
        pageRects = pages.map { page in
            let rect = CGRect(x: (contentWidth - page.size.width) / 2, y: y,
                              width: page.size.width, height: page.size.height)
            y += page.size.height + pageGap
            return rect
        }
        contentHeight = y - pageGap + margin + 90
    }

    /// Rebuilds layout and ink after the page list changed. Clears undo history.
    private func rebuild(scrollTo target: Int? = nil) {
        reloadPages()
        computeLayout()
        isSettingDrawing = true
        canvasView.drawing = composeDrawing()
        isSettingDrawing = false
        strokeCount = canvasView.drawing.strokes.count
        history.removeAllActions()
        recognizer = nil
        for view in pageViews.values { view.removeFromSuperview() }
        pageViews.removeAll()
        for view in elementViews.values { view.removeFromSuperview() }
        elementViews.removeAll()
        if canvasView.bounds.width > 0 {
            configureZoom(preserveRelative: fitScale > 0)
            if let target { scrollToPage(target, animated: false) }
        } else {
            pendingScrollPage = target
        }
        layoutPageContent()
        refreshSelection()
        updateUndoState()
    }

    private func configureZoom(preserveRelative: Bool) {
        let width = canvasView.bounds.width
        guard width > 0, contentWidth > 0 else { return }
        let anchor: CGRect? = (preserveRelative && fitScale > 0) ? visibleCanvasRect() : nil
        let relative = (preserveRelative && fitScale > 0) ? canvasView.zoomScale / fitScale : 1
        if horizontal {
            // One whole page on screen at "fit".
            let widest = (pages.map { $0.size.width }.max() ?? PageFormat.a4.portraitSize.width) + margin * 2
            let visibleHeight = max(1, canvasView.bounds.height - insets.top - insets.bottom)
            fitScale = min(width / widest, visibleHeight / max(contentHeight, 1))
        } else {
            fitScale = width / contentWidth
        }
        laidOutWidth = width
        canvasView.minimumZoomScale = fitScale * 0.5
        canvasView.maximumZoomScale = fitScale * 6
        canvasView.zoomScale = min(max(fitScale * relative, canvasView.minimumZoomScale), canvasView.maximumZoomScale)
        updateContentSize()
        if let anchor {
            if horizontal {
                scrollToPage(pageIndex(at: CGPoint(x: anchor.midX, y: anchor.midY)), animated: false)
            } else {
                setOffset(y: anchor.minY * canvasView.zoomScale - insets.top, animated: false)
            }
        }
        layoutPageContent()
        scheduleDetailRefresh()
    }

    private func updateContentSize() {
        let z = canvasView.zoomScale
        let size = CGSize(width: contentWidth * z, height: contentHeight * z)
        if canvasView.contentSize != size { canvasView.contentSize = size }
        underlay.frame = CGRect(origin: .zero, size: size)
        let side = max(0, (canvasView.bounds.width - size.width) / 2)
        var top = insets.top
        var bottom = insets.bottom
        if horizontal {
            // Centre the row of pages vertically when it is shorter than the screen.
            let free = canvasView.bounds.height - insets.top - insets.bottom - size.height
            if free > 0 {
                top += free / 2
                bottom += free / 2
            }
        }
        let newInsets = UIEdgeInsets(top: top, left: side, bottom: bottom, right: side)
        if canvasView.contentInset != newInsets { canvasView.contentInset = newInsets }
    }

    func setInsets(top: CGFloat, bottom: CGFloat) {
        guard insets.top != top || insets.bottom != bottom else { return }
        let delta = top - insets.top
        insets = UIEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        updateContentSize()
        if isLoaded, abs(delta) > 0.5 {
            if horizontal {
                configureZoom(preserveRelative: true)
            } else {
                setOffset(y: canvasView.contentOffset.y - delta, animated: false)
            }
        }
    }

    // MARK: Composition (pages ⇄ single canvas drawing)

    private func composeDrawing() -> PKDrawing {
        var strokes: [PKStroke] = []
        for (index, page) in pages.enumerated() {
            guard let drawing = pageDrawings[page.id], !drawing.strokes.isEmpty, pageRects.indices.contains(index) else { continue }
            let origin = pageRects[index].origin
            strokes.append(contentsOf: drawing.transformed(using: CGAffineTransform(translationX: origin.x, y: origin.y)).strokes)
        }
        return PKDrawing(strokes: strokes)
    }

    private func splitDrawing(_ drawing: PKDrawing) -> [UUID: PKDrawing] {
        guard !pages.isEmpty, pages.count == pageRects.count else { return [:] }
        var buckets = Array(repeating: [PKStroke](), count: pages.count)
        for stroke in drawing.strokes {
            let bounds = stroke.renderBounds
            buckets[pageIndex(at: CGPoint(x: bounds.midX, y: bounds.midY))].append(stroke)
        }
        var result: [UUID: PKDrawing] = [:]
        for (index, page) in pages.enumerated() {
            let origin = pageRects[index].origin
            result[page.id] = PKDrawing(strokes: buckets[index])
                .transformed(using: CGAffineTransform(translationX: -origin.x, y: -origin.y))
        }
        return result
    }

    private static func fingerprint(_ drawing: PKDrawing) -> [Double] {
        var dates = 0.0, points = 0.0, geometry = 0.0
        for stroke in drawing.strokes {
            dates += stroke.path.creationDate.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 100_000)
            points += Double(stroke.path.count)
            let b = stroke.renderBounds
            // Rounded so that compose/split round-trips (float noise) don't look like edits.
            geometry += (Double(stroke.transform.tx + stroke.transform.ty + b.minX * 3 + b.maxY * 7) * 100).rounded() / 100
        }
        return [Double(drawing.strokes.count), dates, points, geometry]
    }

    // MARK: Saving ink

    private func scheduleInkSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled else { return }
            self?.commitInk()
        }
    }

    /// Splits the canvas ink into pages and writes the pages that changed.
    func commitInk() {
        saveTask?.cancel()
        saveTask = nil
        guard !isReadOnly, isLoaded, pages.count == pageRects.count, !pages.isEmpty else { return }
        let split = splitDrawing(canvasView.drawing)
        var changed: [UUID: Data] = [:]
        var changedDrawings: [UUID: PKDrawing] = [:]
        for (id, drawing) in split {
            let signature = Self.fingerprint(drawing)
            if savedFingerprints[id] == signature { continue }
            savedFingerprints[id] = signature
            pageDrawings[id] = drawing
            let data = drawing.strokes.isEmpty ? Data() : drawing.dataRepresentation()
            if data != savedData[id] {
                savedData[id] = data
                changed[id] = data
                changedDrawings[id] = drawing
            }
        }
        guard !changed.isEmpty else { return }
        model.store.writeDrawings(changed, notebookID: model.notebookID)
        mutatePages { pages in
            for index in pages.indices where changed[pages[index].id] != nil {
                pages[index].revision += 1
            }
        }
        HandwritingIndexer.shared.schedule(notebookID: model.notebookID, pageIDs: Array(changed.keys),
                                           drawings: changedDrawings)
    }

    // MARK: Tools

    func apply(_ configuration: ToolConfiguration) {
        guard configuration != appliedConfiguration else { return }
        appliedConfiguration = configuration
        switch configuration.tool {
        case .pen, .pencil, .highlighter:
            canvasView.tool = PKInkingTool(configuration.inkType, color: UIColor(hex: configuration.colorHex),
                                           width: configuration.width)
        case .eraser:
            canvasView.tool = configuration.eraserMode == .stroke
                ? PKEraserTool(.vector)
                : PKEraserTool(.fixedWidthBitmap, width: configuration.eraserWidth)
        case .lasso:
            canvasView.tool = PKLassoTool()
        case .laser:
            canvasView.tool = PKInkingTool(.monoline, color: Self.laserColor, width: 4)
        case .text, .hand:
            break
        }
        let laser = configuration.tool == .laser
        let drawingTool = configuration.readOnly ? laser : (configuration.tool != .text && configuration.tool != .hand)
        canvasView.isDrawingEnabled = drawingTool
        canvasView.isRulerActive = configuration.ruler && !configuration.readOnly && !laser
        // Without a Pencil (iPhone, Mac) the laser follows the finger or the pointer.
        canvasView.drawingPolicy = configuration.fingerDrawing || (configuration.readOnly && laser) ? .anyInput : .pencilOnly
        let editable = !configuration.readOnly
        elementTap.isEnabled = editable && !drawingTool
        elementDoubleTap.isEnabled = editable && configuration.tool == .hand
        elementPan.isEnabled = editable && configuration.tool == .hand
        touchObserver.isEnabled = editable && configuration.tool.isInk
        // Laser strokes are never part of the notebook: keep them out of undo.
        if laser != laserUndoSuspended {
            laserUndoSuspended = laser
            if laser { history.disableUndoRegistration() } else { history.enableUndoRegistration() }
        }
        // Deferred: this runs inside a SwiftUI update pass.
        let tool = configuration.tool
        Task { [weak self] in
            guard let self else { return }
            if tool != .hand { self.selectElement(nil) }
            if tool != .lasso, !self.canvasView.selection.isEmpty { self.canvasView.selection = [] }
        }
    }

    // MARK: PKCanvasViewDelegate

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !isSettingDrawing, isLoaded else { return }
        if model.tool == .laser || isReadOnly {
            // Deferred: PencilKit is still inside its own update.
            Task { [weak self] in self?.fadeLaserStrokes() }
            return
        }
        let count = canvasView.drawing.strokes.count
        let added = count == strokeCount + 1
        strokeCount = count
        if added, model.tool.isInk {
            Task { [weak self] in self?.snapLastStrokeIfNeeded(expectedCount: count) }
        }
        scheduleInkSave()
    }

    func canvasViewSelectionDidChange(_ canvasView: PKCanvasView) {
        let hasSelection = !canvasView.selection.isEmpty
        if model.hasStrokeSelection != hasSelection { model.hasStrokeSelection = hasSelection }
    }

    // MARK: UIScrollViewDelegate (PKCanvasViewDelegate inherits it)

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        layoutPageContent()
        updateCurrentPage()
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        updateContentSize()
        layoutPageContent()
        if fitScale > 0 {
            let percent = Int((canvasView.zoomScale / fitScale * 100).rounded())
            if model.zoomPercent != percent { model.zoomPercent = percent }
        }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        scheduleDetailRefresh()
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        scheduleDetailRefresh()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { scheduleDetailRefresh() }
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scheduleDetailRefresh()
    }

    // MARK: Visible content

    private func scaled(_ rect: CGRect, _ z: CGFloat) -> CGRect {
        CGRect(x: rect.minX * z, y: rect.minY * z, width: rect.width * z, height: rect.height * z)
    }

    /// Canvas coordinates of a point in the canvas view (content coordinates).
    private func canvasPoint(_ location: CGPoint) -> CGPoint {
        let z = max(canvasView.zoomScale, 0.001)
        return CGPoint(x: location.x / z, y: location.y / z)
    }

    /// The part of the notebook currently on screen (excluding toolbar insets), in canvas coordinates.
    private func visibleCanvasRect() -> CGRect {
        let z = max(canvasView.zoomScale, 0.001)
        let b = canvasView.bounds
        let height = max(1, b.height - insets.top - insets.bottom)
        return CGRect(x: b.minX / z, y: (b.minY + insets.top) / z, width: b.width / z, height: height / z)
    }

    private func pageIndex(at point: CGPoint) -> Int {
        guard !pageRects.isEmpty else { return 0 }
        if horizontal {
            for (index, rect) in pageRects.enumerated() where point.x < rect.maxX + pageGap {
                return index
            }
            return pageRects.count - 1
        }
        for (index, rect) in pageRects.enumerated() where point.y < rect.maxY + pageGap / 2 {
            return index
        }
        return pageRects.count - 1
    }

    private func updateCurrentPage() {
        guard !pageRects.isEmpty else { return }
        let visible = visibleCanvasRect()
        let index = pageIndex(at: CGPoint(x: visible.midX, y: horizontal ? visible.midY : visible.minY + visible.height * 0.4))
        if model.currentPageIndex != index { model.currentPageIndex = index }
    }

    private func layoutPageContent() {
        guard pages.count == pageRects.count, !pages.isEmpty else { return }
        let z = canvasView.zoomScale
        let visible = visibleCanvasRect()
        let window = horizontal
            ? visible.insetBy(dx: -visible.width * 0.8, dy: -visible.height * 0.25)
            : visible.insetBy(dx: -visible.width * 0.25, dy: -visible.height * 0.8)
        let pixelScale = max(traitCollection.displayScale, 1)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        var visibleIDs = Set<UUID>()
        for (index, page) in pages.enumerated() where pageRects[index].intersects(window) {
            visibleIDs.insert(page.id)
            let view: PageBackgroundView
            if let existing = pageViews[page.id] {
                view = existing
                view.update(page: page)
            } else {
                view = PageBackgroundView(page: page, files: files, cache: backgroundCache)
                pagesContainer.addSubview(view)
                pageViews[page.id] = view
            }
            view.frame = scaled(pageRects[index], z)
            view.ensureBase(pixelWidth: page.size.width * max(fitScale, 0.1) * pixelScale)
        }
        for (id, view) in pageViews where !visibleIDs.contains(id) {
            view.removeFromSuperview()
            pageViews[id] = nil
        }
        layoutElements(visiblePageIDs: visibleIDs, zoom: z)
        layoutHighlights(zoom: z)
        if drag == nil { refreshSelection() }
        CATransaction.commit()
    }

    private func scheduleDetailRefresh() {
        detailTask?.cancel()
        detailTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(140))
            guard !Task.isCancelled else { return }
            self?.refreshDetail()
        }
    }

    /// Re-renders the visible part of zoomed-in pages at screen resolution.
    private func refreshDetail() {
        guard pages.count == pageRects.count else { return }
        let z = canvasView.zoomScale
        let pixelScale = max(traitCollection.displayScale, 1)
        let visible = visibleCanvasRect()
        for (index, page) in pages.enumerated() {
            guard let view = pageViews[page.id] else { continue }
            let rect = pageRects[index]
            let needsDetail = page.size.width * z * pixelScale > view.basePixelWidth * 1.15
            let overlap = rect.intersection(visible)
            if needsDetail, !overlap.isNull, !overlap.isEmpty {
                let region = overlap.offsetBy(dx: -rect.minX, dy: -rect.minY)
                    .insetBy(dx: -30 / z, dy: -30 / z)
                    .intersection(page.bounds)
                view.updateDetail(region: region, pixelScale: z * pixelScale)
            } else {
                view.clearDetail()
            }
        }
    }

    private func layoutElements(visiblePageIDs: Set<UUID>, zoom z: CGFloat) {
        var needed = Set<UUID>()
        var created = false
        for (index, page) in pages.enumerated() where visiblePageIDs.contains(page.id) {
            let origin = pageRects[index].origin
            for element in page.elements {
                needed.insert(element.id)
                let view: ElementView
                if let existing = elementViews[element.id], existing.element.kind == element.kind {
                    view = existing
                    view.update(element)
                } else {
                    elementViews[element.id]?.removeFromSuperview()
                    view = ElementView.make(for: element, files: files)
                    elementsContainer.addSubview(view)
                    elementViews[element.id] = view
                    created = true
                }
                if drag?.elementID != element.id {
                    view.frame = scaled(element.frame.offsetBy(dx: origin.x, dy: origin.y), z)
                }
            }
        }
        for (id, view) in elementViews where !needed.contains(id) {
            view.removeFromSuperview()
            elementViews[id] = nil
        }
        if created { reorderElementViews() }
    }

    /// Element views follow the page's element order (last = front).
    private func reorderElementViews() {
        for page in pages {
            for element in page.elements {
                if let view = elementViews[element.id] { elementsContainer.bringSubviewToFront(view) }
            }
        }
    }

    // MARK: Navigation

    func scrollToPage(_ index: Int, animated: Bool) {
        guard pageRects.indices.contains(index) else { return }
        let z = canvasView.zoomScale
        if horizontal {
            setOffset(y: canvasView.contentOffset.y, x: centeredOffsetX(for: index), animated: animated)
        } else {
            setOffset(y: pageRects[index].minY * z - insets.top - 10, animated: animated)
        }
        if model.currentPageIndex != index { model.currentPageIndex = index }
    }

    /// Centres a canvas rectangle on screen.
    func reveal(_ rect: CGRect, animated: Bool) {
        let z = canvasView.zoomScale
        let visibleHeight = canvasView.bounds.height - insets.top - insets.bottom
        let y = rect.midY * z - visibleHeight / 2 - insets.top
        let x = rect.midX * z - canvasView.bounds.width / 2
        setOffset(y: y, x: x, animated: animated)
    }

    private func setOffset(y: CGFloat, x: CGFloat? = nil, animated: Bool) {
        let inset = canvasView.contentInset
        let minY = -inset.top
        let maxY = max(minY, canvasView.contentSize.height + inset.bottom - canvasView.bounds.height)
        let minX = -inset.left
        let maxX = max(minX, canvasView.contentSize.width + inset.right - canvasView.bounds.width)
        let targetX = min(max(x ?? canvasView.contentOffset.x, minX), maxX)
        let targetY = min(max(y, minY), maxY)
        canvasView.setContentOffset(CGPoint(x: targetX, y: targetY), animated: animated)
    }

    func zoomToFitWidth() {
        canvasView.setZoomScale(fitScale, animated: true)
        if horizontal { scrollToPage(model.currentPageIndex, animated: true) }
    }

    /// Content offset that centres page `index` horizontally.
    private func centeredOffsetX(for index: Int) -> CGFloat {
        let z = canvasView.zoomScale
        return pageRects[index].midX * z - canvasView.bounds.width / 2
    }

    /// Switches between vertical and side-by-side pages, staying on the same page.
    func applyScrollDirection() {
        let target = model.isHorizontal
        guard target != horizontal else { return }
        let page = model.currentPageIndex
        if !isReadOnly { commitInk() }
        horizontal = target
        canvasView.alwaysBounceVertical = !horizontal
        canvasView.alwaysBounceHorizontal = horizontal
        canvasView.showsVerticalScrollIndicator = !horizontal
        canvasView.decelerationRate = horizontal ? .fast : .normal
        fitScale = 0
        rebuild(scrollTo: page)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        dragStartPage = model.currentPageIndex
    }

    /// Page turning: at "fit" zoom, a swipe lands exactly on the previous or next page.
    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        guard horizontal, !pageRects.isEmpty, canvasView.zoomScale <= fitScale * 1.08 else { return }
        let current = dragStartPage
        var target = current
        if velocity.x > 0.25 {
            target = current + 1
        } else if velocity.x < -0.25 {
            target = current - 1
        } else {
            let z = canvasView.zoomScale
            let centre = (targetContentOffset.pointee.x + canvasView.bounds.width / 2) / max(z, 0.001)
            target = pageIndex(at: CGPoint(x: centre, y: pageRects[min(current, pageRects.count - 1)].midY))
        }
        target = min(max(target, 0), pageRects.count - 1)
        let inset = canvasView.contentInset
        let maxX = max(-inset.left, canvasView.contentSize.width + inset.right - canvasView.bounds.width)
        targetContentOffset.pointee.x = min(max(centeredOffsetX(for: target), -inset.left), maxX)
    }

    // MARK: Undo / redo

    func undo() {
        guard history.canUndo else { return }
        history.undo()
        afterHistoryChange()
    }

    func redo() {
        guard history.canRedo else { return }
        history.redo()
        afterHistoryChange()
    }

    private func afterHistoryChange() {
        strokeCount = canvasView.drawing.strokes.count
        reloadPages()
        layoutPageContent()
        refreshSelection()
        scheduleInkSave()
        updateUndoState()
    }

    @objc private func undoStateChanged(_ note: Notification) {
        updateUndoState()
    }

    private func updateUndoState() {
        if model.canUndo != history.canUndo { model.canUndo = history.canUndo }
        if model.canRedo != history.canRedo { model.canRedo = history.canRedo }
    }

    @objc private func handleUndoTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, history.canUndo else { return }
        undo()
        model.flash("Annulé")
    }

    @objc private func handleRedoTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended, history.canRedo else { return }
        redo()
        model.flash("Rétabli")
    }

    /// Replaces the canvas ink as one undoable step.
    private func setDrawing(_ drawing: PKDrawing, previous: PKDrawing, actionName: String) {
        isSettingDrawing = true
        canvasView.drawing = drawing
        isSettingDrawing = false
        strokeCount = drawing.strokes.count
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.setDrawing(previous, previous: drawing, actionName: actionName)
            }
        }
        history.setActionName(actionName)
        scheduleInkSave()
        updateUndoState()
    }

    // MARK: Laser pointer

    static let laserColor = UIColor(red: 1, green: 0.23, blue: 0.19, alpha: 1)

    /// Takes the strokes just drawn with the laser off the page and lets them glow and fade.
    private func fadeLaserStrokes() {
        let drawing = canvasView.drawing
        guard drawing.strokes.count > strokeCount else { return }
        let laser = Array(drawing.strokes[strokeCount...])
        var restored = drawing
        restored.strokes = Array(drawing.strokes.prefix(strokeCount))
        isSettingDrawing = true
        canvasView.drawing = restored
        isSettingDrawing = false

        var bounds = CGRect.null
        for stroke in laser { bounds = bounds.union(stroke.renderBounds) }
        guard !bounds.isNull else { return }
        bounds = bounds.insetBy(dx: -6, dy: -6)
        let z = canvasView.zoomScale
        let image = PKDrawing(strokes: laser).image(from: bounds, scale: z * max(traitCollection.displayScale, 1))
        let glow = UIImageView(image: image)
        glow.frame = scaled(bounds, z)
        glow.isUserInteractionEnabled = false
        glow.layer.shadowColor = Self.laserColor.cgColor
        glow.layer.shadowOpacity = 0.9
        glow.layer.shadowRadius = 6
        glow.layer.shadowOffset = .zero
        canvasView.addSubview(glow)
        UIView.animate(withDuration: 0.9, delay: 0.7, options: [.curveEaseIn, .allowUserInteraction]) {
            glow.alpha = 0
        } completion: { _ in
            glow.removeFromSuperview()
        }
    }

    // MARK: Shapes

    private func snapLastStrokeIfNeeded(expectedCount: Int) {
        let held = touchObserver.consumeHold()
        guard canvasView.drawing.strokes.count == expectedCount else { return }
        guard model.alwaysSnapShapes || (held && model.settings.holdToSnapShapes) else { return }
        var drawing = canvasView.drawing
        guard let last = drawing.strokes.last, let snapped = ShapeRecognizer.snap(last) else { return }
        let before = drawing
        drawing.strokes[drawing.strokes.count - 1] = snapped
        setDrawing(drawing, previous: before, actionName: "Forme")
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    // MARK: Apple Pencil double-tap / squeeze

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveTap tap: UIPencilInteraction.Tap) {
        handlePencilAction(UIPencilInteraction.preferredTapAction)
    }

    func pencilInteraction(_ interaction: UIPencilInteraction, didReceiveSqueeze squeeze: UIPencilInteraction.Squeeze) {
        guard squeeze.phase == .ended else { return }
        handlePencilAction(UIPencilInteraction.preferredSqueezeAction)
    }

    private func handlePencilAction(_ action: UIPencilPreferredAction) {
        if isReadOnly {
            if action != .ignore { model.select(.laser) }
            return
        }
        switch action {
        case .ignore, .runSystemShortcut:
            break
        case .switchPrevious:
            model.switchToPreviousTool()
        case .showColorPalette, .showInkAttributes, .showContextualPalette:
            model.showToolOptions.toggle()
        default:
            model.toggleEraser()
        }
    }

    // MARK: Gesture delegate

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === touchObserver || other === touchObserver
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === elementPan && other === canvasView.panGestureRecognizer
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === undoTap || gestureRecognizer === redoTap {
            return model.settings.tapGesturesForUndo && !isReadOnly
        }
        guard gestureRecognizer === elementPan else { return true }
        let translation = elementPan.translation(in: canvasView)
        let now = elementPan.location(in: canvasView)
        let start = CGPoint(x: now.x - translation.x, y: now.y - translation.y)
        if let id = model.selectedElementID, let location = locateElement(id), !selectionView.isHidden,
           selectionView.handleFrame.insetBy(dx: -8, dy: -8).contains(start) {
            let page = pages[location.pageIndex]
            drag = ElementDrag(pageIndex: location.pageIndex, elementID: id, mode: .resize,
                               original: page.elements[location.elementIndex].frame,
                               originalElements: page.elements)
            return true
        }
        if let hit = elementHit(at: canvasPoint(start)), let location = locateElement(hit) {
            selectElement(hit)
            let page = pages[location.pageIndex]
            drag = ElementDrag(pageIndex: location.pageIndex, elementID: hit, mode: .move,
                               original: page.elements[location.elementIndex].frame,
                               originalElements: page.elements)
            return true
        }
        return false
    }

    // MARK: Elements

    private func locateElement(_ id: UUID) -> (pageIndex: Int, elementIndex: Int)? {
        for (pageIndex, page) in pages.enumerated() {
            if let elementIndex = page.elements.firstIndex(where: { $0.id == id }) {
                return (pageIndex, elementIndex)
            }
        }
        return nil
    }

    private func elementHit(at point: CGPoint) -> UUID? {
        let index = pageIndex(at: point)
        guard pages.indices.contains(index) else { return nil }
        let origin = pageRects[index].origin
        for element in pages[index].elements.reversed()
        where element.frame.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: -6, dy: -6).contains(point) {
            return element.id
        }
        return nil
    }

    private func selectElement(_ id: UUID?) {
        if model.selectedElementID != id { model.selectedElementID = id }
        refreshSelection()
    }

    private func refreshSelection() {
        guard let id = model.selectedElementID, let location = locateElement(id) else {
            selectionView.isHidden = true
            return
        }
        let element = pages[location.pageIndex].elements[location.elementIndex]
        let origin = pageRects[location.pageIndex].origin
        selectionView.show(around: scaled(element.frame.offsetBy(dx: origin.x, dy: origin.y), canvasView.zoomScale))
        canvasView.bringSubviewToFront(selectionView)
    }

    /// Replaces a page's elements as one undoable step.
    private func setElements(_ elements: [PageElement], previous: [PageElement], pageID: UUID, actionName: String) {
        mutatePages { pages in
            guard let index = pages.firstIndex(where: { $0.id == pageID }) else { return }
            pages[index].elements = elements
            pages[index].revision += 1
        }
        history.registerUndo(withTarget: self) { target in
            MainActor.assumeIsolated {
                target.setElements(previous, previous: elements, pageID: pageID, actionName: actionName)
            }
        }
        history.setActionName(actionName)
        if let selected = model.selectedElementID, locateElement(selected) == nil {
            model.selectedElementID = nil
        }
        layoutPageContent()
        reorderElementViews()
        refreshSelection()
        updateUndoState()
    }

    @objc private func handleElementTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let point = canvasPoint(g.location(in: canvasView))
        switch model.tool {
        case .hand:
            selectElement(elementHit(at: point))
        case .text:
            if let hit = elementHit(at: point), let location = locateElement(hit),
               pages[location.pageIndex].elements[location.elementIndex].kind == .text {
                requestTextEdit(hit)
            } else {
                createTextBox(at: point)
            }
        default:
            break
        }
    }

    @objc private func handleElementDoubleTap(_ g: UITapGestureRecognizer) {
        guard g.state == .ended else { return }
        let point = canvasPoint(g.location(in: canvasView))
        guard let hit = elementHit(at: point), let location = locateElement(hit) else { return }
        selectElement(hit)
        if pages[location.pageIndex].elements[location.elementIndex].kind == .text {
            requestTextEdit(hit)
        }
    }

    @objc private func handleElementPan(_ g: UIPanGestureRecognizer) {
        guard let drag else { return }
        guard pages.indices.contains(drag.pageIndex),
              let elementIndex = pages[drag.pageIndex].elements.firstIndex(where: { $0.id == drag.elementID }) else {
            self.drag = nil
            return
        }
        let z = max(canvasView.zoomScale, 0.001)
        let translation = g.translation(in: canvasView)
        let dx = translation.x / z, dy = translation.y / z
        var element = pages[drag.pageIndex].elements[elementIndex]
        var frame = drag.original
        switch drag.mode {
        case .move:
            frame.origin.x += dx
            frame.origin.y += dy
        case .resize:
            if element.kind == .image {
                let aspect = frame.height / max(frame.width, 1)
                let width = max(40, frame.width + dx)
                frame.size = CGSize(width: width, height: width * aspect)
            } else {
                frame.size.width = max(80, frame.width + dx)
                frame.size.height = PageRenderer.textHeight(element.text, width: frame.width, element: element)
            }
        }
        let bounds = pages[drag.pageIndex].bounds
        frame.origin.x = min(max(frame.origin.x, -frame.width * 0.5), bounds.width - frame.width * 0.5)
        frame.origin.y = min(max(frame.origin.y, -frame.height * 0.5), bounds.height - frame.height * 0.5)
        element.frame = frame

        switch g.state {
        case .changed:
            let origin = pageRects[drag.pageIndex].origin
            let rect = scaled(frame.offsetBy(dx: origin.x, dy: origin.y), z)
            if let view = elementViews[element.id] {
                view.update(element)
                view.frame = rect
            }
            selectionView.show(around: rect)
        case .ended:
            var elements = pages[drag.pageIndex].elements
            elements[elementIndex] = element
            let pageID = pages[drag.pageIndex].id
            self.drag = nil
            setElements(elements, previous: drag.originalElements, pageID: pageID,
                        actionName: drag.mode == .move ? "Déplacement" : "Redimensionnement")
        case .cancelled, .failed:
            self.drag = nil
            layoutPageContent()
        default:
            break
        }
    }

    private func createTextBox(at point: CGPoint) {
        let index = pageIndex(at: point)
        guard pages.indices.contains(index) else { return }
        let page = pages[index]
        let origin = pageRects[index].origin
        let local = CGPoint(x: point.x - origin.x, y: point.y - origin.y)
        let width = min(320, max(140, page.size.width * 0.5))
        let x = min(max(16, local.x), page.size.width - width - 16)
        let y = min(max(16, local.y - 14), page.size.height - 60)
        let color = model.currentPaperIsDark ? "#F5F5F7" : model.settings.tools.penColor
        let element = PageElement.makeText("", frame: CGRect(x: x, y: y, width: width, height: 40),
                                           fontSize: 18, style: .sans, colorHex: color)
        model.textEdit = TextEditRequest(pageID: page.id, elementID: nil, element: element)
    }

    private func requestTextEdit(_ id: UUID) {
        guard let location = locateElement(id) else { return }
        let page = pages[location.pageIndex]
        model.textEdit = TextEditRequest(pageID: page.id, elementID: id, element: page.elements[location.elementIndex])
    }

    /// Applies the text editor sheet's result.
    func commitText(_ request: TextEditRequest, text: String, fontSize: Double, style: TextFontStyle, colorHex: String) {
        guard let pageIndex = pages.firstIndex(where: { $0.id == request.pageID }) else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let previous = pages[pageIndex].elements
        var elements = previous
        var element = request.element
        element.text = text
        element.fontSize = fontSize
        element.fontStyle = style
        element.colorHex = colorHex
        element.height = Double(PageRenderer.textHeight(text, width: CGFloat(element.width), element: element))
        if let id = request.elementID, let index = elements.firstIndex(where: { $0.id == id }) {
            if trimmed.isEmpty {
                elements.remove(at: index)
            } else {
                element.x = elements[index].x
                element.y = elements[index].y
                element.width = elements[index].width
                element.height = Double(PageRenderer.textHeight(text, width: CGFloat(element.width), element: element))
                elements[index] = element
            }
        } else {
            guard !trimmed.isEmpty else { return }
            elements.append(element)
        }
        setElements(elements, previous: previous, pageID: request.pageID, actionName: "Texte")
        if !trimmed.isEmpty {
            model.tool = .hand
            selectElement(element.id)
        }
    }

    func deleteSelectedElement() {
        guard let id = model.selectedElementID, let location = locateElement(id) else { return }
        let page = pages[location.pageIndex]
        var elements = page.elements
        elements.remove(at: location.elementIndex)
        selectElement(nil)
        setElements(elements, previous: page.elements, pageID: page.id, actionName: "Suppression")
    }

    func duplicateSelectedElement() {
        guard let id = model.selectedElementID, let location = locateElement(id) else { return }
        let page = pages[location.pageIndex]
        var copy = page.elements[location.elementIndex]
        copy.id = UUID()
        copy.x += 24
        copy.y += 24
        var elements = page.elements
        elements.append(copy)
        setElements(elements, previous: page.elements, pageID: page.id, actionName: "Duplication")
        selectElement(copy.id)
    }

    func bringSelectedElementToFront() {
        guard let id = model.selectedElementID, let location = locateElement(id) else { return }
        let page = pages[location.pageIndex]
        var elements = page.elements
        let element = elements.remove(at: location.elementIndex)
        elements.append(element)
        setElements(elements, previous: page.elements, pageID: page.id, actionName: "Premier plan")
    }

    func editSelectedText() {
        guard let id = model.selectedElementID else { return }
        requestTextEdit(id)
    }

    var selectedElementIsText: Bool {
        guard let id = model.selectedElementID, let location = locateElement(id) else { return false }
        return pages[location.pageIndex].elements[location.elementIndex].kind == .text
    }

    /// Places a photo on the current page and selects it.
    func insertImage(_ image: UIImage) {
        guard pages.indices.contains(model.currentPageIndex) else { return }
        let pageID = pages[model.currentPageIndex].id
        let files = self.files
        Task {
            let stored = await Task.detached(priority: .userInitiated) {
                Importer.storeImage(image, in: files, maxPixel: 2048)
            }.value
            guard let stored, let index = self.pages.firstIndex(where: { $0.id == pageID }) else {
                self.model.flash("Impossible d’insérer cette image")
                return
            }
            let page = self.pages[index]
            let pixel = stored.1
            let aspect = pixel.height / max(pixel.width, 1)
            var width = page.size.width * 0.6
            var height = width * aspect
            if height > page.size.height * 0.6 {
                height = page.size.height * 0.6
                width = height / max(aspect, 0.01)
            }
            let pageRect = self.pageRects[index]
            let visible = self.visibleCanvasRect().intersection(pageRect)
            let center = visible.isNull || visible.isEmpty
                ? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
                : CGPoint(x: visible.midX - pageRect.minX, y: visible.midY - pageRect.minY)
            let frame = CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)
            let element = PageElement.makeImage(file: stored.0, frame: frame)
            var elements = page.elements
            elements.append(element)
            self.setElements(elements, previous: page.elements, pageID: page.id, actionName: "Image")
            self.model.tool = .hand
            self.selectElement(element.id)
        }
    }

    // MARK: Pages

    /// Inserts a blank page after `index`, matching that page's size and paper.
    func insertPage(after index: Int, template: PageTemplate? = nil, paper: PaperStyle? = nil) {
        commitInk()
        guard let notebook = model.notebook else { return }
        var page = notebook.makeDefaultPage(template: template)
        if pages.indices.contains(index) {
            let reference = pages[index]
            page = NotebookPage(size: reference.size,
                                background: .template(template ?? reference.background.template ?? notebook.defaultTemplate),
                                paper: reference.paper)
        }
        if let paper { page.paper = paper }
        let position = min(max(index + 1, 0), pages.count)
        let newPage = page
        mutatePages { $0.insert(newPage, at: position) }
        pageDrawings[newPage.id] = PKDrawing()
        savedData[newPage.id] = Data()
        savedFingerprints[newPage.id] = Self.fingerprint(PKDrawing())
        rebuild(scrollTo: position)
        model.flash("Page \(position + 1) ajoutée")
    }

    /// Inserts pages built elsewhere (imported PDF, scans, photos) after `index`.
    func insertPages(_ newPages: [NotebookPage], after index: Int) {
        guard !newPages.isEmpty else { return }
        commitInk()
        let position = min(max(index + 1, 0), pages.count)
        mutatePages { $0.insert(contentsOf: newPages, at: position) }
        for page in newPages {
            pageDrawings[page.id] = PKDrawing()
            savedData[page.id] = Data()
            savedFingerprints[page.id] = Self.fingerprint(PKDrawing())
        }
        HandwritingIndexer.shared.schedule(notebookID: model.notebookID, pageIDs: newPages.map(\.id))
        rebuild(scrollTo: position)
        model.flash(newPages.count == 1 ? "1 page ajoutée" : "\(newPages.count) pages ajoutées")
    }

    func duplicatePage(at index: Int) {
        commitInk()
        guard pages.indices.contains(index) else { return }
        let original = pages[index]
        var copy = original
        copy.id = UUID()
        copy.elements = original.elements.map { var e = $0; e.id = UUID(); return e }
        copy.isBookmarked = false
        let drawing = pageDrawings[original.id] ?? PKDrawing()
        let data = drawing.strokes.isEmpty ? Data() : drawing.dataRepresentation()
        mutatePages { $0.insert(copy, at: index + 1) }
        pageDrawings[copy.id] = drawing
        savedData[copy.id] = data
        savedFingerprints[copy.id] = Self.fingerprint(drawing)
        model.store.writeDrawings([copy.id: data], notebookID: model.notebookID)
        rebuild(scrollTo: index + 1)
        model.flash("Page dupliquée")
    }

    func deletePage(at index: Int) {
        commitInk()
        guard pages.indices.contains(index) else { return }
        if pages.count == 1 {
            clearPage(at: 0)
            return
        }
        let id = pages[index].id
        mutatePages { $0.remove(at: index) }
        pageDrawings[id] = nil
        savedData[id] = nil
        savedFingerprints[id] = nil
        model.store.writeDrawings([id: Data()], notebookID: model.notebookID)
        rebuild(scrollTo: min(index, pages.count - 1))
        model.flash("Page supprimée")
    }

    /// Moves the page at `source` so that it ends up at index `destination`.
    func movePage(from source: Int, to destination: Int) {
        guard pages.indices.contains(source), pages.indices.contains(destination), source != destination else { return }
        commitInk()
        mutatePages { pages in
            let page = pages.remove(at: source)
            pages.insert(page, at: destination)
        }
        rebuild(scrollTo: destination)
    }

    /// Erases all ink on a page (undoable).
    func clearPage(at index: Int) {
        guard pages.indices.contains(index), pageRects.indices.contains(index) else { return }
        let before = canvasView.drawing
        var after = before
        after.strokes.removeAll { pageIndex(at: CGPoint(x: $0.renderBounds.midX, y: $0.renderBounds.midY)) == index }
        guard after.strokes.count != before.strokes.count else { return }
        setDrawing(after, previous: before, actionName: "Effacer la page")
    }

    /// Changes paper and/or template of one page (or all pages).
    func setAppearance(template: PageTemplate?, paper: PaperStyle?, pageIndex: Int, allPages: Bool) {
        mutatePages { pages in
            for index in pages.indices where allPages || index == pageIndex {
                if let template, pages[index].background.isTemplate {
                    pages[index].background = .template(template)
                }
                if let paper { pages[index].paper = paper }
                pages[index].revision += 1
            }
        }
        if allPages, let template {
            model.store.update(model.notebookID) { notebook in
                notebook.defaultTemplate = template
                if let paper { notebook.defaultPaper = paper }
            }
        }
        layoutPageContent()
        scheduleDetailRefresh()
    }

    /// Names a page; named pages make up the notebook's outline (« Plan »).
    func setPageTitle(_ title: String, at index: Int) {
        guard pages.indices.contains(index) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard pages[index].title != trimmed else { return }
        mutatePages { $0[index].title = trimmed }
        model.flash(trimmed.isEmpty ? "Titre de la page retiré" : "Page \(index + 1) : « \(trimmed) »")
    }

    func toggleBookmark(at index: Int) {
        guard pages.indices.contains(index) else { return }
        mutatePages(touch: false) { $0[index].isBookmarked.toggle() }
        model.flash(pages[index].isBookmarked ? "Marque-page ajouté" : "Marque-page retiré")
    }

    /// Current per-page ink (after committing), for thumbnails in the page navigator.
    func drawingsSnapshot() -> [UUID: PKDrawing] {
        commitInk()
        return pageDrawings
    }

    // MARK: Export

    func exportPDF(pageIndices: [Int]?) async throws -> URL {
        commitInk()
        guard let notebook = model.notebook else { throw CarnetsError.emptyImport }
        let drawings = pageDrawings
        let files = self.files
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(PageRenderer.exportFileName(notebook.title, ext: "pdf"))
        try await Task.detached(priority: .userInitiated) {
            try? FileManager.default.removeItem(at: url)
            try PageRenderer.exportPDF(notebook: notebook, files: files, drawings: drawings,
                                       pageIndices: pageIndices, to: url)
        }.value
        return url
    }

    func exportPageImage(at index: Int) async -> URL? {
        commitInk()
        guard pages.indices.contains(index), let notebook = model.notebook else { return nil }
        let page = pages[index]
        let drawing = pageDrawings[page.id]
        let files = self.files
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(PageRenderer.exportFileName(notebook.title, suffix: " – page \(index + 1)", ext: "png"))
        let written = await Task.detached(priority: .userInitiated) { () -> Bool in
            let image = PageRenderer.renderPage(page: page, files: files, drawing: drawing, scale: 3)
            guard let data = image.pngData() else { return false }
            return (try? data.write(to: url, options: .atomic)) != nil
        }.value
        return written ? url : nil
    }

    // MARK: Handwriting → text

    func recognizedText(ofPage index: Int) async -> String {
        commitInk()
        guard pages.indices.contains(index) else { return "" }
        let page = pages[index]
        var parts: [String] = []
        if let drawing = pageDrawings[page.id], !drawing.strokes.isEmpty {
            let result = await HandwritingIndexer.recognize(drawing, languages: HandwritingIndexer.languages)
            parts.append(result.text)
        }
        parts += page.elements.filter { $0.kind == .text }.map(\.text)
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// Recognises the lasso selection and opens the conversion sheet.
    func convertSelectionToText() async {
        let ids = canvasView.selection
        guard !ids.isEmpty else {
            model.flash("Entourez d’abord de l’écriture avec le lasso")
            return
        }
        let strokes = canvasView.drawing.strokes.filter { ids.contains($0.id) }
        guard !strokes.isEmpty else { return }
        let drawing = PKDrawing(strokes: strokes)
        model.busyMessage = "Reconnaissance de l’écriture…"
        let result = await HandwritingIndexer.recognize(drawing, languages: HandwritingIndexer.languages)
        model.busyMessage = nil
        guard !result.text.isEmpty else {
            model.flash("Aucune écriture reconnue")
            return
        }
        model.conversion = ConversionResult(text: result.text, strokeIDs: ids, bounds: drawing.bounds)
    }

    /// Replaces the converted strokes with a text box at the same place (undoable).
    func replaceStrokesWithText(_ conversion: ConversionResult, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !pageRects.isEmpty else { return }
        let before = canvasView.drawing
        let converted = before.strokes.filter { conversion.strokeIDs.contains($0.id) }
        var after = before
        after.strokes.removeAll { conversion.strokeIDs.contains($0.id) }

        let index = pageIndex(at: CGPoint(x: conversion.bounds.midX, y: conversion.bounds.midY))
        let page = pages[index]
        let origin = pageRects[index].origin
        let local = conversion.bounds.offsetBy(dx: -origin.x, dy: -origin.y)
        let lines = CGFloat(max(1, trimmed.components(separatedBy: "\n").count))
        let fontSize = min(40, max(11, local.height / lines * 0.62))
        var hex = model.settings.tools.penColor
        if let color = converted.first?.ink.color {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            color.getRed(&r, green: &g, blue: &b, alpha: &a)
            hex = RGBA(Double(r), Double(g), Double(b)).hex
        }
        var element = PageElement.makeText(trimmed, frame: local, fontSize: Double(fontSize), style: .sans, colorHex: hex)
        element.width = Double(min(max(local.width + 24, 140), page.size.width - 16))
        element.x = Double(min(max(8, local.minX), page.size.width - CGFloat(element.width) - 8))
        element.height = Double(PageRenderer.textHeight(trimmed, width: CGFloat(element.width), element: element))

        history.beginUndoGrouping()
        setDrawing(after, previous: before, actionName: "Conversion en texte")
        var elements = page.elements
        elements.append(element)
        setElements(elements, previous: page.elements, pageID: page.id, actionName: "Conversion en texte")
        history.endUndoGrouping()
        canvasView.selection = []
        model.flash("Écriture convertie en texte")
    }

    // MARK: Search

    func search(_ query: String) async -> [SearchHit] {
        commitInk()
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        var results: [SearchHit] = []

        let drawing = canvasView.drawing
        if !drawing.strokes.isEmpty {
            let recognizer = self.recognizer ?? PKStrokeRecognizer(preferredLanguages: HandwritingIndexer.languages)
            self.recognizer = recognizer
            await recognizer.updateDrawing(drawing)
            let matches = await recognizer.search(q)
            for match in matches {
                results.append(SearchHit(rect: match.bounds,
                                         pageIndex: pageIndex(at: CGPoint(x: match.bounds.midX, y: match.bounds.midY))))
            }
        }

        let needle = LibrarySearch.normalized(q)
        for (index, page) in pages.enumerated() where pageRects.indices.contains(index) {
            let origin = pageRects[index].origin
            for element in page.elements where element.kind == .text && LibrarySearch.normalized(element.text).contains(needle) {
                results.append(SearchHit(rect: element.frame.offsetBy(dx: origin.x, dy: origin.y), pageIndex: index))
            }
        }
        results += pdfHits(q)
        return results.sorted { a, b in
            a.pageIndex != b.pageIndex ? a.pageIndex < b.pageIndex : a.rect.minY < b.rect.minY
        }
    }

    private func pdfHits(_ query: String) -> [SearchHit] {
        var byFile: [String: [Int: Int]] = [:]   // file → pdf page index → notebook page index
        for (index, page) in pages.enumerated() {
            if case let .pdf(file, pdfIndex) = page.background { byFile[file, default: [:]][pdfIndex] = index }
        }
        var results: [SearchHit] = []
        for (file, mapping) in byFile {
            guard let document = PDFDocument(url: files.assetURL(file)) else { continue }
            for selection in document.findString(query, withOptions: [.caseInsensitive, .diacriticInsensitive]) {
                for pdfPage in selection.pages {
                    let pdfIndex = document.index(for: pdfPage)
                    guard let index = mapping[pdfIndex], pageRects.indices.contains(index) else { continue }
                    let page = pages[index]
                    let box = pdfPage.bounds(for: .cropBox)
                    let found = selection.bounds(for: pdfPage)
                    var rect: CGRect
                    if pdfPage.rotation % 360 == 0, box.width > 0, box.height > 0 {
                        let sx = page.size.width / box.width, sy = page.size.height / box.height
                        rect = CGRect(x: (found.minX - box.minX) * sx, y: (box.maxY - found.maxY) * sy,
                                      width: found.width * sx, height: found.height * sy)
                    } else {
                        rect = CGRect(x: 0, y: page.size.height * 0.45, width: page.size.width, height: page.size.height * 0.1)
                    }
                    rect = rect.offsetBy(dx: pageRects[index].minX, dy: pageRects[index].minY)
                    results.append(SearchHit(rect: rect, pageIndex: index))
                }
            }
        }
        return results
    }

    func showSearchHits(_ newHits: [SearchHit], current: Int) {
        hits = newHits
        currentHitIndex = current
        layoutHighlights(zoom: canvasView.zoomScale)
        if hits.indices.contains(current) { reveal(hits[current].rect, animated: true) }
    }

    private func layoutHighlights(zoom z: CGFloat) {
        while highlightLayers.count < hits.count {
            let layer = CALayer()
            layer.cornerRadius = 3
            layer.actions = ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            highlightsContainer.layer.addSublayer(layer)
            highlightLayers.append(layer)
        }
        while highlightLayers.count > hits.count {
            highlightLayers.removeLast().removeFromSuperlayer()
        }
        for (index, layer) in highlightLayers.enumerated() {
            layer.frame = scaled(hits[index].rect.insetBy(dx: -3, dy: -2), z)
            layer.backgroundColor = (index == currentHitIndex
                ? UIColor.systemOrange.withAlphaComponent(0.42)
                : UIColor.systemYellow.withAlphaComponent(0.32)).cgColor
        }
    }
}
