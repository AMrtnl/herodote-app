import UIKit
import UIKit.UIGestureRecognizerSubclass

// MARK: - PageBackgroundView
// Shows a page's paper/template/PDF without ever allocating a full-resolution backing
// store: a "base" image rendered at fit-to-width resolution, plus a "detail" image of
// just the visible region, rendered at screen resolution when zoomed in.

final class PageBackgroundView: UIView {
    private(set) var page: NotebookPage
    private let files: NotebookFiles
    private let cache: NSCache<NSString, UIImage>

    private let baseLayer = CALayer()
    private let detailLayer = CALayer()
    private var detailRegion: CGRect = .null
    private var baseKey: String?
    private var baseToken = 0
    private var detailToken = 0
    private(set) var basePixelWidth: CGFloat = 0

    init(page: NotebookPage, files: NotebookFiles, cache: NSCache<NSString, UIImage>) {
        self.page = page
        self.files = files
        self.cache = cache
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = UIColor(rgba: page.paper.fill)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.14
        layer.shadowRadius = 5
        layer.shadowOffset = CGSize(width: 0, height: 1.5)
        let noAnimations: [String: CAAction] = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull()]
        for sublayer in [baseLayer, detailLayer] {
            sublayer.contentsGravity = .resize
            sublayer.actions = noAnimations
            sublayer.minificationFilter = .trilinear
            layer.addSublayer(sublayer)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseLayer.frame = bounds
        if detailRegion.isNull {
            detailLayer.frame = .zero
        } else {
            let s = bounds.width / max(page.size.width, 1)
            detailLayer.frame = CGRect(x: detailRegion.minX * s, y: detailRegion.minY * s,
                                       width: detailRegion.width * s, height: detailRegion.height * s)
        }
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        CATransaction.commit()
    }

    /// Updates the page model; drops rendered images only when the background really changed.
    func update(page newPage: NotebookPage) {
        let backgroundChanged = newPage.background != page.background
            || newPage.paper != page.paper
            || newPage.size != page.size
        page = newPage
        guard backgroundChanged else { return }
        backgroundColor = UIColor(rgba: newPage.paper.fill)
        baseKey = nil
        baseToken += 1
        clearDetail()
        baseLayer.contents = nil
    }

    /// Makes sure a base image of roughly `pixelWidth` pixels exists.
    func ensureBase(pixelWidth: CGFloat) {
        let px = min(max(pixelWidth, 300), 2048).rounded()
        let key = "\(page.id.uuidString)|\(String(describing: page.background))|\(page.paper.rawValue)|\(Int(px))"
        guard key != baseKey else { return }
        baseKey = key
        basePixelWidth = px
        if let cached = cache.object(forKey: key as NSString) {
            setContents(baseLayer, cached)
            return
        }
        baseToken += 1
        let token = baseToken
        let page = self.page, files = self.files
        let scale = px / max(page.size.width, 1)
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                PageRenderer.renderBackground(page: page, files: files, region: page.bounds, scale: scale)
            }.value
            guard let self, self.baseToken == token else { return }
            let cost = Int(image.size.width * image.scale * image.size.height * image.scale * 4)
            self.cache.setObject(image, forKey: key as NSString, cost: cost)
            self.setContents(self.baseLayer, image)
        }
    }

    /// Renders `region` (page coordinates) at `pixelScale` pixels per point, or clears the detail.
    func updateDetail(region: CGRect?, pixelScale: CGFloat) {
        guard let region, !region.isEmpty, region.width > 1, region.height > 1 else {
            clearDetail()
            return
        }
        // Keep the detail bitmap bounded (≈ 16 Mpx).
        let maxSide = max(region.width, region.height) * pixelScale
        let scale = maxSide > 4096 ? pixelScale * 4096 / maxSide : pixelScale
        detailToken += 1
        let token = detailToken
        let page = self.page, files = self.files
        Task { [weak self] in
            let image = await Task.detached(priority: .userInitiated) {
                PageRenderer.renderBackground(page: page, files: files, region: region, scale: scale)
            }.value
            guard let self, self.detailToken == token else { return }
            self.detailRegion = region
            self.setContents(self.detailLayer, image)
            self.setNeedsLayout()
        }
    }

    func clearDetail() {
        detailToken += 1
        detailRegion = .null
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        detailLayer.contents = nil
        detailLayer.frame = .zero
        CATransaction.commit()
    }

    private func setContents(_ target: CALayer, _ image: UIImage) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        target.contents = image.cgImage
        CATransaction.commit()
    }
}

// MARK: - Element views

/// Base class: an element drawn on a page, positioned by the canvas controller.
class ElementView: UIView {
    private(set) var element: PageElement
    let files: NotebookFiles

    init(element: PageElement, files: NotebookFiles) {
        self.element = element
        self.files = files
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        render()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(_ newElement: PageElement) {
        guard newElement != element else { return }
        element = newElement
        render()
    }

    /// Subclasses refresh their content.
    func render() {}

    static func make(for element: PageElement, files: NotebookFiles) -> ElementView {
        switch element.kind {
        case .image: return ImageElementView(element: element, files: files)
        case .text:  return TextElementView(element: element, files: files)
        }
    }
}

final class ImageElementView: ElementView {
    override func render() {
        layer.contentsGravity = .resize
        layer.minificationFilter = .trilinear
        guard let file = element.file else { layer.contents = nil; return }
        layer.contents = ImageCache.shared.image(at: files.assetURL(file))?.cgImage
    }
}

final class TextElementView: ElementView {
    override init(element: PageElement, files: NotebookFiles) {
        super.init(element: element, files: files)
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func render() { setNeedsDisplay() }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Text is redrawn crisply at every zoom level, but never with a huge backing store.
        let longest = max(bounds.width, bounds.height, 1)
        let screenScale = max(traitCollection.displayScale, 1)
        let scale = min(screenScale, 4096 / longest)
        if abs(contentScaleFactor - scale) > 0.01 { contentScaleFactor = scale }
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext(), element.width > 0 else { return }
        let s = bounds.width / CGFloat(element.width)
        ctx.scaleBy(x: s, y: s)
        let text = NSAttributedString(string: element.text, attributes: PageRenderer.textAttributes(for: element))
        text.draw(with: CGRect(x: 0, y: 0, width: element.width, height: element.height + 2000),
                  options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
    }
}

// MARK: - Selection overlay (dashed frame + resize handle)

final class SelectionOverlayView: UIView {
    static let handleRadius: CGFloat = 11

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// `rect` is the selected element's frame in the canvas' content coordinates.
    func show(around rect: CGRect) {
        let r = Self.handleRadius
        frame = rect.insetBy(dx: -r, dy: -r)
        isHidden = false
        setNeedsDisplay()
    }

    /// Handle rectangle in the canvas' content coordinates.
    var handleFrame: CGRect {
        let r = Self.handleRadius
        return CGRect(x: frame.maxX - r * 2.6, y: frame.maxY - r * 2.6, width: r * 2.6, height: r * 2.6)
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let r = Self.handleRadius
        let box = bounds.insetBy(dx: r, dy: r)
        let tint = UIColor.systemBlue
        ctx.setStrokeColor(tint.cgColor)
        ctx.setLineWidth(1.5)
        ctx.setLineDash(phase: 0, lengths: [6, 4])
        ctx.stroke(box)
        ctx.setLineDash(phase: 0, lengths: [])
        let handle = CGRect(x: box.maxX - r * 0.8, y: box.maxY - r * 0.8, width: r * 1.6, height: r * 1.6)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillEllipse(in: handle)
        ctx.setLineWidth(2)
        ctx.strokeEllipse(in: handle)
    }
}

// MARK: - StrokeTouchObserver
// Watches touches without interfering, to detect "draw and hold" at the end of a stroke.

final class StrokeTouchObserver: UIGestureRecognizer {
    var holdDuration: TimeInterval = 0.5

    private weak var tracked: UITouch?
    private var anchor: CGPoint = .zero
    private var lastMoveTime: TimeInterval = 0
    private var endedHeld = false
    private var endedAt: TimeInterval = 0

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    /// True once if the last single-touch stroke ended after holding still (within the last second).
    func consumeHold() -> Bool {
        defer { endedHeld = false }
        return endedHeld && ProcessInfo.processInfo.systemUptime - endedAt < 1.5
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if tracked == nil, touches.count == 1, (event.allTouches?.count ?? 1) == 1, let touch = touches.first {
            tracked = touch
            anchor = touch.location(in: view)
            lastMoveTime = touch.timestamp
            endedHeld = false
        } else {
            tracked = nil
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        let p = touch.location(in: view)
        if hypot(p.x - anchor.x, p.y - anchor.y) > 3 {
            anchor = p
            lastMoveTime = touch.timestamp
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracked, touches.contains(touch) else { return }
        endedHeld = touch.timestamp - lastMoveTime >= holdDuration
        endedAt = touch.timestamp
        tracked = nil
        state = .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        tracked = nil
        endedHeld = false
        state = .failed
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}
