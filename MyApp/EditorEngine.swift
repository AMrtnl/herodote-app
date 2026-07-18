import AppKit
import SwiftUI

// MARK: - EditorState

@Observable final class EditorState {
    @ObservationIgnored weak var textView: NSTextView?
    var hasSelection = false
    var wordCount = 0

    // Set by EditorDetailView so menu commands and the palette can trigger sheet-level actions.
    @ObservationIgnored var requestSaveVersion: (() -> Void)?
    @ObservationIgnored var requestHistory:     (() -> Void)?
    @ObservationIgnored var requestExport:      (() -> Void)?
    @ObservationIgnored var requestLink:        (() -> Void)?

    // Version restore must not credit the words-written heatmap
    @ObservationIgnored var suppressNextWordCredit = false

    func refreshStats() {
        guard let tv = textView else { return }
        wordCount = countWords(in: tv.string)
        hasSelection = tv.selectedRange().length > 0
    }

    var selectedRange: NSRange? {
        guard let tv = textView, tv.selectedRange().length > 0 else { return nil }
        return tv.selectedRange()
    }

    // MARK: Formatting — writes Markdown markers (the markup is the source of truth)

    func bold()          { toggleMarkerPair("**") }
    func italic()        { toggleMarkerPair("*") }
    func strikethrough() { toggleMarkerPair("~~") }

    func underline() {
        guard let tv = textView else { return }
        let r = tv.selectedRange()
        if r.length == 0 {
            // No Markdown syntax for underline — toggle the typing attribute instead
            var attrs = tv.typingAttributes
            let cur = attrs[.underlineStyle] as? Int ?? 0
            attrs[.underlineStyle] = cur == 0 ? NSUnderlineStyle.single.rawValue : 0
            tv.typingAttributes = attrs
            return
        }
        let cur = tv.textStorage?.attribute(.underlineStyle, at: r.location, effectiveRange: nil) as? Int ?? 0
        tv.textStorage?.addAttribute(.underlineStyle,
            value: cur == 0 ? NSUnderlineStyle.single.rawValue : 0, range: r)
    }

    /// Insert, replace or toggle a "#…# " prefix on every selected paragraph.
    func heading(_ level: Int) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let paragraphs = MarkdownHighlighter.paragraphRanges(in: ns, within: tv.selectedRange())
        guard !paragraphs.isEmpty else { return }
        let target = max(1, min(level, 3))
        let newPrefix = String(repeating: "#", count: target) + " "
        // Toggle off only when every selected paragraph already has the target level
        let allAtTarget = paragraphs.allSatisfy {
            MarkdownHighlighter.headingPrefix(ns, paragraph: $0)?.level == target
        }
        // Back-to-front so earlier ranges stay valid as the string changes
        for para in paragraphs.reversed() {
            let prefixLen = MarkdownHighlighter.headingPrefix(ns, paragraph: para)?.prefixLen ?? 0
            let existing = NSRange(location: para.location, length: prefixLen)
            replaceUndoSafe(tv, range: existing, with: allAtTarget ? "" : newPrefix)
        }
    }

    func bodyStyle() {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let paragraphs = MarkdownHighlighter.paragraphRanges(in: ns, within: tv.selectedRange())
        for para in paragraphs.reversed() {
            if let prefix = MarkdownHighlighter.headingPrefix(ns, paragraph: para) {
                replaceUndoSafe(tv, range: NSRange(location: para.location, length: prefix.prefixLen), with: "")
            }
        }
        // Reset manual/legacy formatting, then let the highlighter re-derive
        // whatever the remaining markers justify.
        guard let ts = tv.textStorage else { return }
        let current = (tv.string as NSString).paragraphRange(for: tv.selectedRange())
        ts.addAttributes(AppSettings.shared.defaultEditorAttributes, range: current)
        ts.removeAttribute(.herodoteMD, range: current)
        MarkdownHighlighter.highlight(ts, in: current)
        tv.didChangeText()
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

    // MARK: Version restore / navigation

    /// Undo-safe full-document replacement (used by version restore).
    func replaceAll(with content: NSAttributedString) {
        guard let tv = textView, let ts = tv.textStorage else { return }
        let full = NSRange(location: 0, length: ts.length)
        guard tv.shouldChangeText(in: full, replacementString: content.string) else { return }
        suppressNextWordCredit = true
        ts.replaceCharacters(in: full, with: content)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.typingAttributes = AppSettings.shared.defaultEditorAttributes
        refreshStats()
    }

    func scrollTo(range: NSRange) {
        guard let tv = textView else { return }
        let length = (tv.string as NSString).length
        let target = NSRange(location: min(range.location, length), length: 0)
        tv.setSelectedRange(target)
        tv.scrollRangeToVisible(target)
        tv.window?.makeFirstResponder(tv)
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

    // MARK: Marker plumbing

    private func toggleMarkerPair(_ marker: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let mLen = (marker as NSString).length
        var sel = tv.selectedRange()

        if sel.length == 0 {
            // Toggle-off gesture: caret sitting right before a closing marker
            // (⌘B → type → ⌘B) steps past it instead of inserting a new pair
            if sel.location + mLen <= ns.length,
               ns.substring(with: NSRange(location: sel.location, length: mLen)) == marker {
                tv.setSelectedRange(NSRange(location: sel.location + mLen, length: 0))
                return
            }
            // Insert the pair, caret between the markers — typed text lands inside
            if replaceUndoSafe(tv, range: sel, with: marker + marker) {
                tv.setSelectedRange(NSRange(location: sel.location + mLen, length: 0))
            }
            return
        }

        // Markers must hug non-whitespace, so trim the selection edges
        while sel.length > 0, Self.isWhitespace(ns.character(at: sel.location)) {
            sel.location += 1; sel.length -= 1
        }
        while sel.length > 0, Self.isWhitespace(ns.character(at: NSMaxRange(sel) - 1)) {
            sel.length -= 1
        }
        guard sel.length > 0 else { return }

        // Unwrap when the markers sit just outside the selection…
        let lead = NSRange(location: sel.location - mLen, length: mLen)
        let trail = NSRange(location: NSMaxRange(sel), length: mLen)
        if lead.location >= 0, NSMaxRange(trail) <= ns.length,
           ns.substring(with: lead) == marker, ns.substring(with: trail) == marker {
            replaceUndoSafe(tv, range: trail, with: "")
            replaceUndoSafe(tv, range: lead, with: "")
            tv.setSelectedRange(NSRange(location: lead.location, length: sel.length))
            return
        }

        // …or when the selection includes the markers themselves
        if sel.length >= 2 * mLen,
           ns.substring(with: NSRange(location: sel.location, length: mLen)) == marker,
           ns.substring(with: NSRange(location: NSMaxRange(sel) - mLen, length: mLen)) == marker {
            replaceUndoSafe(tv, range: NSRange(location: NSMaxRange(sel) - mLen, length: mLen), with: "")
            replaceUndoSafe(tv, range: NSRange(location: sel.location, length: mLen), with: "")
            tv.setSelectedRange(NSRange(location: sel.location, length: sel.length - 2 * mLen))
            return
        }

        // Wrap — closing first so the opening insertion doesn't shift it
        replaceUndoSafe(tv, range: NSRange(location: NSMaxRange(sel), length: 0), with: marker)
        replaceUndoSafe(tv, range: NSRange(location: sel.location, length: 0), with: marker)
        tv.setSelectedRange(NSRange(location: sel.location + mLen, length: sel.length))
    }

    @discardableResult
    private func replaceUndoSafe(_ tv: NSTextView, range: NSRange, with string: String) -> Bool {
        guard tv.shouldChangeText(in: range, replacementString: string) else { return false }
        tv.textStorage?.replaceCharacters(in: range, with: string)
        tv.didChangeText()
        return true
    }

    private static func isWhitespace(_ c: unichar) -> Bool {
        // Surrogate halves (emoji, etc.) are content, never whitespace
        guard let scalar = UnicodeScalar(c) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
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
        tv.textStorage?.delegate = context.coordinator
        tv.onLinkTap = { url in
            guard let host = url.host, let id = UUID(uuidString: host) else { return }
            context.coordinator.parent.onNavigate(id)
        }
        tv.textStorage?.setAttributedString(sheet.attributedString)
        if let ts = tv.textStorage {
            MarkdownHighlighter.highlight(ts, in: NSRange(location: 0, length: ts.length))
        }
        context.coordinator.pendingHighlightRange = nil
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
            tv.typingAttributes = s.defaultEditorAttributes
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

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: RichTextEditor
        var lastWordCount:        Int    = 0
        var lastFontName:         String = ""
        var lastFontSize:         Double = 0
        var lastLineSpacing:      Double = -1
        var lastParagraphSpacing: Double = -1
        var pendingHighlightRange: NSRange?

        private var resetTypingAttributesAfterNewline = false
        private var lastMarkerParagraph: NSRange?
        private var markerFadeTask: Task<Void, Never>?

        init(parent: RichTextEditor) { self.parent = parent }

        func syncSettings(_ s: AppSettings) {
            lastFontName         = s.fontName
            lastFontSize         = s.fontSize
            lastLineSpacing      = s.lineSpacing
            lastParagraphSpacing = s.paragraphSpacing
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage,
                         didProcessEditing editedMask: NSTextStorage.EditActions,
                         range editedRange: NSRange,
                         changeInLength delta: Int) {
            // Character edits queue a re-highlight. The highlighter's own edits
            // arrive as .editedAttributes only, which breaks the recursion; this
            // also covers paste, undo and programmatic replacement automatically.
            guard editedMask.contains(.editedCharacters) else { return }
            pendingHighlightRange = pendingHighlightRange.map { NSUnionRange($0, editedRange) } ?? editedRange
        }

        // MARK: NSTextViewDelegate

        func textView(_ textView: NSTextView,
                      shouldChangeTextIn affectedCharRange: NSRange,
                      replacementString: String?) -> Bool {
            resetTypingAttributesAfterNewline = replacementString == "\n"
            return true
        }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView,
                  let ts = tv.textStorage else { return }

            // Style before persisting so the snapshot carries the styling
            if let pending = pendingHighlightRange {
                pendingHighlightRange = nil
                MarkdownHighlighter.highlight(ts, in: pending)
            }
            if resetTypingAttributesAfterNewline {
                // Heading style must not leak into the next paragraph
                resetTypingAttributesAfterNewline = false
                tv.typingAttributes = AppSettings.shared.defaultEditorAttributes
            }

            // Persist using NSKeyedArchiver — preserves all attributes including herodote:// links
            let snapshot = NSAttributedString(attributedString: ts)
            parent.sheet.contentData = encodeAttributedString(snapshot)
            parent.sheet.modifiedAt = .now
            parent.state.refreshStats()

            // Track words added for heatmap — but not version restores, and not
            // material (documentation) sheets, which are excluded from stats
            let newCount = parent.state.wordCount
            if parent.state.suppressNextWordCredit {
                parent.state.suppressNextWordCredit = false
            } else if !parent.sheet.isMaterial {
                let delta = max(0, newCount - lastWordCount)
                if delta > 0 { LibraryManager.shared.recordWords(delta) }
            }
            lastWordCount = newCount

            flashMarkers(tv)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.state.hasSelection = tv.selectedRange().length > 0
            parent.state.applyFocusHighlight()
            flashMarkers(tv)
            if AppSettings.shared.writingMode {
                scrollToCenter(tv)
            }
        }

        // MARK: Marker visibility
        // Markers in the caret's paragraph brighten while editing, then fade back
        // to their dim permanent color ~300 ms later. Temporary attributes only —
        // zero undo or persistence impact.

        private func flashMarkers(_ tv: NSTextView) {
            guard !AppSettings.shared.writingMode else {
                // Writing mode owns the temporary-color layer: cancel any pending
                // fade so it can't strip the focus dim after the mode switch
                markerFadeTask?.cancel()
                lastMarkerParagraph = nil
                return
            }
            showMarkers(tv)
            markerFadeTask?.cancel()
            markerFadeTask = Task { @MainActor [weak self, weak tv] in
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self, let tv,
                      !AppSettings.shared.writingMode else { return }
                self.hideMarkers(tv)
            }
        }

        private func showMarkers(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let ts = tv.textStorage, ts.length > 0 else { return }
            hideMarkers(tv)
            let para = (ts.string as NSString).paragraphRange(for: tv.selectedRange())
            for r in MarkdownHighlighter.markerRanges(in: ts, within: para) {
                lm.addTemporaryAttribute(.foregroundColor,
                                         value: NSColor.secondaryLabelColor,
                                         forCharacterRange: r)
            }
            lastMarkerParagraph = para
        }

        private func hideMarkers(_ tv: NSTextView) {
            guard let lm = tv.layoutManager, let ts = tv.textStorage else { return }
            if let prev = lastMarkerParagraph {
                let clamped = NSIntersectionRange(prev, NSRange(location: 0, length: ts.length))
                if clamped.length > 0 {
                    lm.removeTemporaryAttribute(.foregroundColor, forCharacterRange: clamped)
                }
            }
            lastMarkerParagraph = nil
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
