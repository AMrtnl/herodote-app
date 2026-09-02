import AppKit
import SwiftUI

// MARK: - EditorState

@Observable final class EditorState {
    @ObservationIgnored weak var textView: NSTextView?
    var hasSelection = false
    var wordCount = 0

    func refreshStats() {
        guard let tv = textView else { return }
        wordCount = tv.string.split { $0.isWhitespace || $0.isNewline }.filter { !$0.isEmpty }.count
        hasSelection = tv.selectedRange().length > 0
    }

    var selectedRange: NSRange? {
        guard let tv = textView, tv.selectedRange().length > 0 else { return nil }
        return tv.selectedRange()
    }

    // MARK: Formatting

    func bold()   { toggleTrait(.bold) }
    func italic() { toggleTrait(.italic) }

    func underline() {
        guard let tv = textView, tv.selectedRange().length > 0 else { return }
        let r = tv.selectedRange()
        let cur = tv.textStorage?.attribute(.underlineStyle, at: r.location, effectiveRange: nil) as? Int ?? 0
        tv.textStorage?.addAttribute(.underlineStyle,
            value: cur == 0 ? NSUnderlineStyle.single.rawValue : 0, range: r)
    }

    func heading(_ level: Int) {
        guard let tv = textView else { return }
        let r = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
        let font: NSFont = level == 1
            ? .systemFont(ofSize: 30, weight: .bold)
            : .systemFont(ofSize: 22, weight: .semibold)
        tv.textStorage?.addAttribute(.font, value: font, range: r)
    }

    func bodyStyle() {
        guard let tv = textView else { return }
        let r = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
        let settings = AppSettings.shared
        tv.textStorage?.addAttributes([
            .font:            settings.editorFont(),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle:  settings.editorParagraphStyle
        ], range: r)
    }

    // Inserts a clickable herodote:// link at the current position
    func insertLink(targetID: UUID, label: String) {
        guard let tv = textView else { return }
        let url = URL(string: "herodote://\(targetID.uuidString)")!
        let display = label.isEmpty ? "lien" : label
        let linked = NSMutableAttributedString(string: "[\(display)]")
        linked.addAttributes([
            .link:            url,
            .foregroundColor: NSColor.linkColor,
            .underlineStyle:  NSUnderlineStyle.single.rawValue,
            .font:            tv.font ?? NSFont.systemFont(ofSize: 18)
        ], range: NSRange(location: 0, length: linked.length))
        let range = tv.selectedRange()
        tv.textStorage?.replaceCharacters(in: range, with: linked)
        tv.setSelectedRange(NSRange(location: range.location + linked.length, length: 0))
    }

    func highlightCommentRange(_ range: NSRange) {
        textView?.textStorage?.addAttribute(
            .backgroundColor,
            value: NSColor.systemYellow.withAlphaComponent(0.35),
            range: range
        )
    }

    // MARK: Writing mode highlight

    func applyFocusHighlight() {
        guard let tv = textView,
              let lm = tv.layoutManager,
              let ts = tv.textStorage else { return }
        let fullRange = NSRange(location: 0, length: ts.length)
        if !AppSettings.shared.writingMode || fullRange.length == 0 {
            lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
            return
        }
        // Dim all text
        lm.addTemporaryAttribute(.foregroundColor,
                                 value: NSColor.labelColor.withAlphaComponent(0.2),
                                 forCharacterRange: fullRange)
        // Un-dim current paragraph
        let paraRange = (ts.string as NSString).paragraphRange(for: tv.selectedRange())
        if paraRange.length > 0 {
            lm.addTemporaryAttribute(.foregroundColor,
                                     value: NSColor.labelColor,
                                     forCharacterRange: paraRange)
        }
    }

    func clearFocusHighlight() {
        guard let tv = textView,
              let lm = tv.layoutManager,
              let ts = tv.textStorage else { return }
        let fullRange = NSRange(location: 0, length: ts.length)
        lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: fullRange)
    }

    func toggleWritingMode() {
        AppSettings.shared.writingMode.toggle()
        AppSettings.shared.save()
        if AppSettings.shared.writingMode {
            applyFocusHighlight()
        } else {
            clearFocusHighlight()
        }
    }

    private func toggleTrait(_ trait: NSFontDescriptor.SymbolicTraits) {
        guard let tv = textView, tv.selectedRange().length > 0 else { return }
        let r = tv.selectedRange()
        tv.textStorage?.enumerateAttribute(.font, in: r) { val, range, _ in
            let f = val as? NSFont ?? NSFont.systemFont(ofSize: 18)
            let t = f.fontDescriptor.symbolicTraits
            let nt = t.contains(trait) ? t.subtracting(trait) : t.union(trait)
            let newFont = NSFont(descriptor: f.fontDescriptor.withSymbolicTraits(nt), size: f.pointSize) ?? f
            tv.textStorage?.addAttribute(.font, value: newFont, range: range)
        }
    }
}

// MARK: - HerodoTextView
// NSTextView subclass that handles herodote:// link clicks in editable mode
// and shows a pointer cursor on hover over links.

final class HerodoTextView: NSTextView {
    var onLinkTap: ((URL) -> Void)?

    override func mouseDown(with event: NSEvent) {
        if let url = linkURL(at: event), url.scheme == "herodote" {
            onLinkTap?(url)
            return
        }
        super.mouseDown(with: event)
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        guard let ts = textStorage, let lm = layoutManager, let tc = textContainer else { return }
        ts.enumerateAttribute(.link, in: NSRange(location: 0, length: ts.length)) { val, range, _ in
            guard let url = val as? URL, url.scheme == "herodote" else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            lm.enumerateEnclosingRects(forGlyphRange: glyphRange, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: tc) { rect, _ in
                let adjusted = NSRect(
                    x: rect.minX + self.textContainerInset.width,
                    y: rect.minY + self.textContainerInset.height,
                    width: rect.width, height: rect.height
                )
                self.addCursorRect(adjusted, cursor: .pointingHand)
            }
        }
    }

    private func linkURL(at event: NSEvent) -> URL? {
        let point = convert(event.locationInWindow, from: nil)
        guard let lm = layoutManager, let tc = textContainer, let ts = textStorage else { return nil }
        let adjusted = NSPoint(
            x: point.x - textContainerInset.width,
            y: point.y - textContainerInset.height
        )
        let idx = lm.characterIndex(for: adjusted, in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        guard idx < ts.length else { return nil }
        return ts.attribute(.link, at: idx, effectiveRange: nil) as? URL
    }
}

// MARK: - RichTextEditor

struct RichTextEditor: NSViewRepresentable {
    @Binding var sheet: WritingSheet
    let state: EditorState
    var onNavigate: (UUID) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let tv = buildTextView()
        tv.delegate = context.coordinator
        tv.onLinkTap = { url in
            guard let host = url.host, let id = UUID(uuidString: host) else { return }
            context.coordinator.parent.onNavigate(id)
        }
        tv.textStorage?.setAttributedString(sheet.attributedString)
        context.coordinator.lastWordCount = sheet.wordCount
        context.coordinator.syncSettings(AppSettings.shared)
        state.textView = tv
        state.refreshStats()

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? HerodoTextView else { return }
        tv.onLinkTap = { url in
            guard let host = url.host, let id = UUID(uuidString: host) else { return }
            onNavigate(id)
        }
        state.textView = tv

        // Re-apply settings that changed since last update
        let c = context.coordinator
        let s = AppSettings.shared
        let inset = NSSize(width: s.horizontalInset, height: 60)
        if tv.textContainerInset != inset {
            tv.textContainerInset = inset
        }
        // Update body typing defaults (affects new text the user types)
        if s.fontName != c.lastFontName || s.fontSize != c.lastFontSize ||
           s.lineSpacing != c.lastLineSpacing || s.paragraphSpacing != c.lastParagraphSpacing {
            tv.typingAttributes = [
                .font:            s.editorFont(),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle:  s.editorParagraphStyle
            ]
            c.syncSettings(s)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    private func buildTextView() -> HerodoTextView {
        let s = AppSettings.shared
        let tv = HerodoTextView()
        tv.isRichText = true
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = true
        tv.isAutomaticDashSubstitutionEnabled = true
        tv.isContinuousSpellCheckingEnabled = true
        tv.backgroundColor = .clear
        tv.drawsBackground = false
        tv.textColor = .labelColor
        tv.insertionPointColor = .controlAccentColor
        tv.font = s.editorFont()
        tv.textContainerInset = NSSize(width: s.horizontalInset, height: 60)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.isAutomaticLinkDetectionEnabled = false
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        return tv
    }

    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: RichTextEditor
        var lastWordCount:        Int    = 0
        var lastFontName:         String = ""
        var lastFontSize:         Double = 0
        var lastLineSpacing:      Double = -1
        var lastParagraphSpacing: Double = -1

        init(parent: RichTextEditor) { self.parent = parent }

        func syncSettings(_ s: AppSettings) {
            lastFontName         = s.fontName
            lastFontSize         = s.fontSize
            lastLineSpacing      = s.lineSpacing
            lastParagraphSpacing = s.paragraphSpacing
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let ts = tv.textStorage else { return }

            // Persist using NSKeyedArchiver — preserves all attributes including herodote:// links
            let snapshot = NSAttributedString(attributedString: ts)
            parent.sheet.contentData = encodeAttributedString(snapshot)
            parent.sheet.modifiedAt = .now
            parent.state.refreshStats()

            // Track words added for heatmap
            let newCount = parent.state.wordCount
            let delta = max(0, newCount - lastWordCount)
            if delta > 0 { LibraryManager.shared.recordWords(delta) }
            lastWordCount = newCount
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.state.hasSelection = tv.selectedRange().length > 0
            parent.state.applyFocusHighlight()
            if AppSettings.shared.writingMode {
                scrollToCenter(tv)
            }
        }

        // Typewriter mode: keep the cursor line vertically centered in the scroll view.
        private func scrollToCenter(_ tv: NSTextView) {
            guard let sv = tv.enclosingScrollView,
                  let lm = tv.layoutManager,
                  let tc = tv.textContainer,
                  let ts = tv.textStorage, ts.length > 0 else { return }

            let sel      = tv.selectedRange()
            let charIdx  = min(sel.location, ts.length - 1)
            let glyphLoc = lm.glyphIndexForCharacter(at: charIdx)
            let glyphRange = NSRange(location: glyphLoc == NSNotFound ? 0 : glyphLoc, length: 1)
            let glyphRect  = lm.boundingRect(forGlyphRange: glyphRange, in: tc)

            let lineY      = glyphRect.midY + tv.textContainerInset.height
            let visibleH   = sv.contentView.bounds.height
            let targetY    = max(0, lineY - visibleH / 2)

            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.14
                ctx.allowsImplicitAnimation = true
                sv.contentView.animator().setBoundsOrigin(NSPoint(x: 0, y: targetY))
                sv.reflectScrolledClipView(sv.contentView)
            }
        }
    }
}
