import SwiftUI
import UIKit
import PencilKit

// MARK: - ThumbnailCache

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 500
        return cache
    }()
    private var inflight: [String: Task<UIImage, Never>] = [:]

    static func key(notebookID: UUID, page: NotebookPage, maxPixel: CGFloat) -> String {
        "\(notebookID.uuidString)-\(page.id.uuidString)-\(page.revision)-\(Int(maxPixel))"
    }

    func cached(_ key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func thumbnail(for page: NotebookPage, notebookID: UUID, drawing: PKDrawing? = nil,
                   maxPixel: CGFloat) async -> UIImage {
        let key = Self.key(notebookID: notebookID, page: page, maxPixel: maxPixel)
        if let image = cached(key) { return image }
        if let running = inflight[key] { return await running.value }
        // Ink read from disk must include the editor's latest save.
        if drawing == nil { await NotebookStore.shared.pendingWritesFlushed() }
        if let image = cached(key) { return image }
        if let running = inflight[key] { return await running.value }
        let files = NotebookStore.shared.files(for: notebookID)
        let task = Task.detached(priority: .utility) {
            PageRenderer.renderThumbnail(page: page, files: files, drawing: drawing, maxPixel: maxPixel)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        cache.setObject(image, forKey: key as NSString)
        return image
    }
}

// MARK: - PageThumbnailView

struct PageThumbnailView: View {
    let page: NotebookPage
    let notebookID: UUID
    var drawing: PKDrawing? = nil
    var maxPixel: CGFloat = 360

    @State private var image: UIImage?

    private var key: String { ThumbnailCache.key(notebookID: notebookID, page: page, maxPixel: maxPixel) }

    var body: some View {
        Color(rgba: page.paper.fill)
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                }
            }
            .aspectRatio(CGFloat(page.width / max(page.height, 1)), contentMode: .fit)
            .clipped()
            .task(id: key) {
                if let cached = ThumbnailCache.shared.cached(key) {
                    image = cached
                    return
                }
                image = await ThumbnailCache.shared.thumbnail(for: page, notebookID: notebookID,
                                                              drawing: drawing, maxPixel: maxPixel)
            }
    }
}

// MARK: - Colour helpers

extension Color {
    init(rgba: RGBA) {
        self.init(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }

    init(hex: String) {
        self.init(rgba: RGBA(hex: hex) ?? RGBA(0, 0, 0))
    }

    /// "#RRGGBB" for an arbitrary SwiftUI colour.
    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(Double(r), Double(g), Double(b)).hex
    }
}

extension UIColor {
    convenience init(rgba: RGBA) {
        self.init(red: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    convenience init(hex: String) {
        self.init(rgba: RGBA(hex: hex) ?? RGBA(0, 0, 0))
    }
}
