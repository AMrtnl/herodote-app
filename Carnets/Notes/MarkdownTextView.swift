import UIKit
import SwiftUI

// MARK: - Custom attributes

extension NSAttributedString.Key {
    static let wikiTarget = NSAttributedString.Key("CarnetsWikiTarget")
    static let taskToggle = NSAttributedString.Key("CarnetsTaskToggle")
    static let externalURL = NSAttributedString.Key("CarnetsExternalURL")
}

// MARK: - Theme

struct MarkdownTheme: Equatable {
    var serif = false
    var fontSize: CGFloat = 17
    var lineSpacing: CGFloat = 4

    func font(size: CGFloat? = nil, weight: UIFont.Weight = .regular, italic: Bool = false) -> UIFont {
        let s = size ?? fontSize
        var font = UIFont.systemFont(ofSize: s, weight: weight)
        if serif, let d = font.fontDescriptor.withDesign(.serif) { font = UIFont(descriptor: d, size: s) }
        if italic, let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(.traitItalic)) {
            font = UIFont(descriptor: d, size: s)
        }
        return font
    }

    var mono: UIFont { UIFont.monospacedSystemFont(ofSize: fontSize * 0.88, weight: .regular) }
}

// MARK: - Highlighter (styles Markdown in place; the text itself stays plain Markdown)

final class MarkdownHighlighter {
    var theme = MarkdownTheme()
    /// In writing mode, everything outside this paragraph is dimmed.
    var focusParagraph: NSRange?

    private let accent = UIColor(named: "AccentColor") ?? .systemOrange

    private static func regex(_ pattern: String, _ options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let heading = regex(#"^(#{1,6})[ \t]+.*$"#, .anchorsMatchLines)
    private static let quote = regex(#"^>[^\n]*$"#, .anchorsMatchLines)
    private static let task = regex(#"^([ \t]*[-*+][ \t]+)\[( |x|X)\][ \t][^\n]*$"#, .anchorsMatchLines)
    private static let list = regex(#"^([ \t]*)([-*+]|\d+[.)])[ \t]+"#, .anchorsMatchLines)
    private static let rule = regex(#"^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$"#, .anchorsMatchLines)
    private static let bold = regex(#"(\*\*|__)(?=\S)(.+?)(?<=\S)\1"#)
    private static let italic = regex(#"(?<![\*\w])\*(?![\*\s])(.+?)(?<![\*\s])\*(?![\*\w])|(?<![_\w])_(?![_\s])(.+?)(?<![_\s])_(?![_\w])"#)
    private static let strike = regex(#"~~(?=\S)(.+?)(?<=\S)~~"#)
    private static let mark = regex(#"==(?=\S)(.+?)(?<=\S)=="#)
    private static let mdLink = regex(#"(!?)\[([^\]\n]*)\]\(([^)\n]+)\)"#)
    private static let bareURL = regex(#"https?://[^\s<>()\[\]]+"#)

    /// Restyles the whole document (inside begin/endEditing).
    func highlightAll(_ storage: NSTextStorage) {
        storage.beginEditing()
        style(storage, range: NSRange(location: 0, length: storage.length))
        storage.endEditing()
    }

    /// Restyles what an edit touched. Call from `textStorage(_:didProcessEditing:…)`.
    func highlightEdit(_ storage: NSTextStorage, editedRange: NSRange) {
        let text = storage.string as NSString
        let touchesStructure = text.length < 20_000
            || text.substring(with: text.paragraphRange(for: editedRange)).contains("```")
            || (MarkdownSyntax.frontmatterRange(in: text).map { NSLocationInRange(editedRange.location, $0) || editedRange.location <= $0.length } ?? false)
        let range = touchesStructure ? NSRange(location: 0, length: text.length) : text.paragraphRange(for: editedRange)
        style(storage, range: range)
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: theme.font(), .foregroundColor: UIColor.label, .paragraphStyle: paragraph()]
    }

    private func paragraph(indent: CGFloat = 0, spacingBefore: CGFloat = 0) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = theme.lineSpacing
        p.paragraphSpacing = theme.lineSpacing * 1.5
        p.paragraphSpacingBefore = spacingBefore
        p.headIndent = indent
        return p
    }

    private func style(_ storage: NSTextStorage, range requested: NSRange) {
        let string = storage.string
        let text = string as NSString
        guard text.length > 0 else { return }
        let range = text.paragraphRange(for: requested)
        let full = NSRange(location: 0, length: text.length)
        storage.setAttributes(baseAttributes, range: range)

        let marker = UIColor.tertiaryLabel
        let secondary = UIColor.secondaryLabel
        var protected: [NSRange] = []

        // Front matter
        if let fm = MarkdownSyntax.frontmatterRange(in: text) {
            protected.append(fm)
            let r = NSIntersectionRange(fm, range)
            if r.length > 0 {
                storage.addAttributes([.font: UIFont.monospacedSystemFont(ofSize: theme.fontSize * 0.76, weight: .regular),
                                       .foregroundColor: secondary], range: r)
            }
        }
        // Fenced code
        for match in MarkdownSyntax.codeFence.matches(in: string, range: full) {
            protected.append(match.range)
            let r = NSIntersectionRange(match.range, range)
            if r.length > 0 {
                storage.addAttributes([.font: theme.mono, .backgroundColor: UIColor.secondarySystemFill,
                                       .foregroundColor: UIColor.label], range: r)
            }
        }
        func isProtected(_ r: NSRange) -> Bool { protected.contains { NSIntersectionRange($0, r).length > 0 } }

        // Block-level
        for m in Self.heading.matches(in: string, range: range) where !isProtected(m.range) {
            let level = m.range(at: 1).length
            let scale: CGFloat = [1.6, 1.38, 1.2, 1.08, 1.0, 1.0][level - 1]
            storage.addAttributes([.font: theme.font(size: theme.fontSize * scale, weight: level <= 2 ? .bold : .semibold),
                                   .paragraphStyle: paragraph(spacingBefore: theme.fontSize * 0.5)], range: m.range)
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location, length: level))
        }
        for m in Self.quote.matches(in: string, range: range) where !isProtected(m.range) {
            storage.addAttributes([.foregroundColor: secondary, .font: theme.font(italic: true),
                                   .paragraphStyle: paragraph(indent: 18)], range: m.range)
            storage.addAttribute(.foregroundColor, value: accent, range: NSRange(location: m.range.location, length: 1))
        }
        for m in Self.list.matches(in: string, range: range) where !isProtected(m.range) {
            let markerRange = m.range(at: 2)
            storage.addAttribute(.foregroundColor, value: accent, range: markerRange)
            let line = text.lineRange(for: m.range)
            let indent = CGFloat(m.range.length) * theme.fontSize * 0.52
            storage.addAttribute(.paragraphStyle, value: paragraph(indent: indent), range: line)
        }
        for m in Self.task.matches(in: string, range: range) where !isProtected(m.range) {
            let box = NSRange(location: m.range(at: 1).location + m.range(at: 1).length, length: 3)
            let done = text.substring(with: m.range(at: 2)).lowercased() == "x"
            storage.addAttributes([.foregroundColor: accent, .font: theme.mono, .taskToggle: box.location], range: box)
            if done {
                let rest = NSRange(location: box.location + 3, length: m.range.location + m.range.length - box.location - 3)
                storage.addAttributes([.foregroundColor: secondary,
                                       .strikethroughStyle: NSUnderlineStyle.single.rawValue], range: rest)
            }
        }
        for m in Self.rule.matches(in: string, range: range) where !isProtected(m.range) {
            storage.addAttribute(.foregroundColor, value: marker, range: m.range)
        }

        // Inline code first, so other inline styles skip it
        for m in MarkdownSyntax.inlineCode.matches(in: string, range: range) where !isProtected(m.range) {
            storage.addAttributes([.font: theme.mono, .backgroundColor: UIColor.secondarySystemFill], range: m.range)
            protected.append(m.range)
        }
        func inline(_ regex: NSRegularExpression, markerLength: Int, attributes: (NSTextCheckingResult) -> [NSAttributedString.Key: Any]) {
            for m in regex.matches(in: string, range: range) where !isProtected(m.range) {
                storage.addAttributes(attributes(m), range: m.range)
                if markerLength > 0, m.range.length > markerLength * 2 {
                    storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location, length: markerLength))
                    storage.addAttribute(.foregroundColor, value: marker,
                                         range: NSRange(location: m.range.location + m.range.length - markerLength, length: markerLength))
                }
            }
        }
        inline(Self.bold, markerLength: 2) { [theme] m in
            let current = storage.attribute(.font, at: m.range.location, effectiveRange: nil) as? UIFont ?? theme.font()
            let traits = current.fontDescriptor.symbolicTraits.union(.traitBold)
            let font = current.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: current.pointSize) } ?? current
            return [.font: font]
        }
        inline(Self.italic, markerLength: 1) { [theme] m in
            let current = storage.attribute(.font, at: m.range.location, effectiveRange: nil) as? UIFont ?? theme.font()
            let traits = current.fontDescriptor.symbolicTraits.union(.traitItalic)
            let font = current.fontDescriptor.withSymbolicTraits(traits).map { UIFont(descriptor: $0, size: current.pointSize) } ?? current
            return [.font: font]
        }
        inline(Self.strike, markerLength: 2) { _ in [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: secondary] }
        inline(Self.mark, markerLength: 2) { _ in [.backgroundColor: UIColor.systemYellow.withAlphaComponent(0.35)] }

        // Wiki links [[Note]], [[Note|alias]], embeds ![[…]]
        for m in MarkdownSyntax.wikiLink.matches(in: string, range: range) where !isProtected(m.range) {
            let inner = text.substring(with: m.range(at: 2))
            let target = MarkdownSyntax.parseLink(inner).target
            storage.addAttributes([.foregroundColor: accent, .wikiTarget: target], range: m.range)
            let openLength = m.range(at: 1).length + 2
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location, length: openLength))
            storage.addAttribute(.foregroundColor, value: marker, range: NSRange(location: m.range.location + m.range.length - 2, length: 2))
            if let bar = inner.firstIndex(of: "|") {
                let hidden = inner.distance(from: inner.startIndex, to: bar) + 1
                storage.addAttribute(.foregroundColor, value: marker,
                                     range: NSRange(location: m.range(at: 2).location, length: (inner.prefix(hidden) as Substring).utf16.count))
            }
        }
        // Markdown links [text](url)
        for m in Self.mdLink.matches(in: string, range: range) where !isProtected(m.range) {
            let destination = text.substring(with: m.range(at: 3))
            storage.addAttribute(.foregroundColor, value: accent, range: m.range(at: 2))
            storage.addAttribute(.foregroundColor, value: marker, range: m.range(at: 3))
            if let url = URL(string: destination.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))), url.scheme != nil {
                storage.addAttribute(.externalURL, value: url, range: m.range(at: 2))
            } else {
                storage.addAttribute(.wikiTarget, value: destination.removingPercentEncoding ?? destination, range: m.range(at: 2))
            }
        }
        for m in Self.bareURL.matches(in: string, range: range) where !isProtected(m.range) {
            if let url = URL(string: text.substring(with: m.range)) {
                storage.addAttributes([.foregroundColor: accent, .underlineStyle: NSUnderlineStyle.single.rawValue,
                                       .externalURL: url], range: m.range)
            }
        }
        // Tags
        for m in MarkdownSyntax.tag.matches(in: string, range: range) where !isProtected(m.range) {
            storage.addAttributes([.foregroundColor: accent, .backgroundColor: accent.withAlphaComponent(0.12)], range: m.range)
        }

        // Writing mode: dim everything but the current paragraph.
        if let focus = focusParagraph {
            let dim = UIColor.label.withAlphaComponent(0.25)
            let before = NSRange(location: range.location, length: max(0, min(focus.location, range.location + range.length) - range.location))
            let afterStart = max(range.location, focus.location + focus.length)
            let after = NSRange(location: afterStart, length: max(0, range.location + range.length - afterStart))
            if before.length > 0 { storage.addAttribute(.foregroundColor, value: dim, range: before) }
            if after.length > 0 { storage.addAttribute(.foregroundColor, value: dim, range: after) }
        }
    }
}

// MARK: - MarkdownTextView (TextKit 1 for precise hit-testing)

final class MarkdownTextView: UITextView, NSTextStorageDelegate, UIGestureRecognizerDelegate {
    let highlighter = MarkdownHighlighter()
    private let markdownStorage: NSTextStorage
    var onOpenLink: ((String) -> Void)?
    var onOpenURL: ((URL) -> Void)?
    var typewriter = false {
        didSet { updateTypewriterInset() }
    }
    var focusMode = false {
        didSet { refreshFocus(force: true) }
    }
    private var isApplyingStyle = false

    init() {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        markdownStorage = storage
        super.init(frame: .zero, textContainer: container)
        storage.delegate = self
        alwaysBounceVertical = true
        keyboardDismissMode = .interactive
        autocorrectionType = .default
        smartDashesType = .no
        smartQuotesType = .no
        textContainerInset = UIEdgeInsets(top: 24, left: 24, bottom: 120, right: 24)
        typingAttributes = highlighter.baseAttributes
        let tap = UITapGestureRecognizer(target: self, action: #selector(handleTap(_:)))
        tap.delegate = self
        addGestureRecognizer(tap)
        inputAccessoryView = MarkdownAccessoryBar(textView: self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    func setMarkdown(_ markdown: String) {
        isApplyingStyle = true
        markdownStorage.beginEditing()
        markdownStorage.setAttributedString(NSAttributedString(string: markdown, attributes: highlighter.baseAttributes))
        markdownStorage.endEditing()
        isApplyingStyle = false
        highlighter.highlightAll(markdownStorage)
        typingAttributes = highlighter.baseAttributes
    }

    func applyTheme(_ theme: MarkdownTheme) {
        guard theme != highlighter.theme else { return }
        highlighter.theme = theme
        highlighter.highlightAll(markdownStorage)
        typingAttributes = highlighter.baseAttributes
    }

    func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions,
                     range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters), !isApplyingStyle else { return }
        highlighter.highlightEdit(textStorage, editedRange: editedRange)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateTypewriterInset()
        // Comfortable measure on wide screens (≈ 72 characters).
        let maxWidth: CGFloat = highlighter.theme.fontSize * 38
        let side = max(24, (bounds.width - maxWidth) / 2)
        if abs(textContainerInset.left - side) > 0.5 {
            textContainerInset = UIEdgeInsets(top: textContainerInset.top, left: side,
                                              bottom: textContainerInset.bottom, right: side)
        }
    }

    // MARK: Writing mode

    private func updateTypewriterInset() {
        let bottom = typewriter ? bounds.height * 0.5 : 120
        if abs(textContainerInset.bottom - bottom) > 0.5 {
            textContainerInset = UIEdgeInsets(top: textContainerInset.top, left: textContainerInset.left,
                                              bottom: bottom, right: textContainerInset.right)
        }
    }

    /// Keeps the caret line at a fixed height, like a typewriter.
    func centerCaretIfNeeded(animated: Bool = true) {
        guard typewriter, let range = selectedTextRange else { return }
        let caret = caretRect(for: range.end)
        guard !caret.isNull, !caret.isInfinite else { return }
        let target = caret.midY - bounds.height * 0.42
        let minY = -adjustedContentInset.top
        let maxY = max(minY, contentSize.height + adjustedContentInset.bottom - bounds.height)
        let y = min(max(target, minY), maxY)
        if abs(contentOffset.y - y) > 1 { setContentOffset(CGPoint(x: contentOffset.x, y: y), animated: animated) }
    }

    private var lastFocus: NSRange?

    func refreshFocus(force: Bool = false) {
        let focus: NSRange? = focusMode
            ? (markdownStorage.string as NSString).paragraphRange(for: NSRange(location: min(selectedRange.location, markdownStorage.length), length: 0))
            : nil
        guard force || focus != lastFocus else { return }
        lastFocus = focus
        highlighter.focusParagraph = focus
        highlighter.highlightAll(markdownStorage)
    }

    // MARK: Taps on links and checkboxes

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }

    @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, markdownStorage.length > 0 else { return }
        var point = gesture.location(in: self)
        point.x -= textContainerInset.left
        point.y -= textContainerInset.top
        let index = layoutManager.characterIndex(for: point, in: textContainer, fractionOfDistanceBetweenInsertionPoints: nil)
        guard index < markdownStorage.length else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        guard rect.insetBy(dx: -6, dy: -4).contains(point) else { return }
        let attributes = markdownStorage.attributes(at: index, effectiveRange: nil)
        if let location = attributes[.taskToggle] as? Int {
            toggleTask(at: location)
        } else if let target = attributes[.wikiTarget] as? String {
            onOpenLink?(target)
        } else if let url = attributes[.externalURL] as? URL {
            onOpenURL?(url)
        }
    }

    private func toggleTask(at location: Int) {
        let text = markdownStorage.string as NSString
        guard location + 3 <= text.length else { return }
        let box = text.substring(with: NSRange(location: location, length: 3))
        replace(NSRange(location: location, length: 3), with: box.lowercased() == "[x]" ? "[ ]" : "[x]")
        UISelectionFeedbackGenerator().selectionChanged()
    }

    // MARK: Editing helpers (undoable)

    func replace(_ range: NSRange, with string: String) {
        guard let start = position(from: beginningOfDocument, offset: range.location),
              let end = position(from: start, offset: range.length),
              let textRange = textRange(from: start, to: end) else { return }
        replace(textRange, withText: string)
    }

    /// Wraps the selection (or inserts an empty pair) with Markdown markers.
    func wrap(_ prefix: String, _ suffix: String) {
        let range = selectedRange
        let text = markdownStorage.string as NSString
        let selected = range.length > 0 ? text.substring(with: range) : ""
        replace(range, with: prefix + selected + suffix)
        let cursor = range.location + (prefix as NSString).length + (selected as NSString).length
        selectedRange = NSRange(location: range.length > 0 ? cursor + (suffix as NSString).length : cursor, length: 0)
    }

    /// Adds or removes a prefix at the start of the current line(s).
    func toggleLinePrefix(_ prefix: String) {
        let text = markdownStorage.string as NSString
        let lines = text.lineRange(for: selectedRange)
        let block = text.substring(with: lines)
        let parts = block.components(separatedBy: "\n")
        let allHave = parts.filter { !$0.isEmpty }.allSatisfy { $0.hasPrefix(prefix) }
        let newBlock = parts.enumerated().map { index, line -> String in
            if line.isEmpty && index == parts.count - 1 { return line }
            if allHave { return String(line.dropFirst(prefix.count)) }
            let stripped = line.replacingOccurrences(of: #"^([-*+] \[[ xX]\] |[-*+] |> |\d+\. )"#, with: "", options: .regularExpression)
            return prefix + stripped
        }.joined(separator: "\n")
        replace(lines, with: newBlock)
    }

    /// Cycles the current line through #, ##, ### and plain text.
    func cycleHeading() {
        let text = markdownStorage.string as NSString
        let line = text.lineRange(for: NSRange(location: selectedRange.location, length: 0))
        var content = text.substring(with: line)
        let hadNewline = content.hasSuffix("\n")
        if hadNewline { content.removeLast() }
        let level = content.prefix(while: { $0 == "#" }).count
        let body = content.drop(while: { $0 == "#" }).drop(while: { $0 == " " })
        let next = level >= 3 ? "" : String(repeating: "#", count: level + 1) + " "
        replace(line, with: next + body + (hadNewline ? "\n" : ""))
    }

    func insertAtCursor(_ string: String) {
        replace(selectedRange, with: string)
    }

    /// The `[[query` being typed before the caret, if any.
    func currentLinkQuery() -> (query: String, range: NSRange)? {
        let selection = selectedRange
        guard selection.length == 0 else { return nil }
        let text = markdownStorage.string as NSString
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        guard selection.location >= line.location else { return nil }
        let before = text.substring(with: NSRange(location: line.location, length: selection.location - line.location)) as NSString
        let open = before.range(of: "[[", options: .backwards)
        guard open.location != NSNotFound else { return nil }
        let query = before.substring(from: open.location + 2)
        guard !query.contains("]]"), !query.contains("|"), query.count <= 80 else { return nil }
        let start = line.location + open.location + 2
        return (query, NSRange(location: start, length: selection.location - start))
    }

    /// Completes the link being typed.
    func completeLink(range: NSRange, title: String) {
        let text = markdownStorage.string as NSString
        let after = range.location + range.length
        let hasClosing = after + 2 <= text.length && text.substring(with: NSRange(location: after, length: 2)) == "]]"
        replace(range, with: title + (hasClosing ? "" : "]]"))
        selectedRange = NSRange(location: range.location + (title as NSString).length + 2, length: 0)
    }

    /// Scrolls so that `location` is near the top.
    func scrollTo(location: Int) {
        guard location <= markdownStorage.length else { return }
        let glyph = layoutManager.glyphIndexForCharacter(at: min(location, max(0, markdownStorage.length - 1)))
        let rect = layoutManager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: textContainer)
        let y = max(-adjustedContentInset.top, rect.minY + textContainerInset.top - 12)
        setContentOffset(CGPoint(x: 0, y: min(y, max(0, contentSize.height - bounds.height))), animated: true)
        selectedRange = NSRange(location: location, length: 0)
    }

    // MARK: Keyboard shortcuts (iPad)

    override var keyCommands: [UIKeyCommand]? {
        [
            UIKeyCommand(title: "Gras", action: #selector(cmdBold), input: "b", modifierFlags: .command),
            UIKeyCommand(title: "Italique", action: #selector(cmdItalic), input: "i", modifierFlags: .command),
            UIKeyCommand(title: "Lien interne", action: #selector(cmdLink), input: "k", modifierFlags: .command),
            UIKeyCommand(title: "Surligner", action: #selector(cmdMark), input: "h", modifierFlags: [.command, .shift]),
            UIKeyCommand(title: "Case à cocher", action: #selector(cmdTask), input: "l", modifierFlags: .command),
        ]
    }

    @objc func cmdBold() { wrap("**", "**") }
    @objc func cmdItalic() { wrap("*", "*") }
    @objc func cmdLink() { wrap("[[", "]]") }
    @objc func cmdMark() { wrap("==", "==") }
    @objc func cmdTask() { toggleLinePrefix("- [ ] ") }
    @objc func cmdHeading() { cycleHeading() }
    @objc func cmdList() { toggleLinePrefix("- ") }
    @objc func cmdQuote() { toggleLinePrefix("> ") }
    @objc func cmdCode() { wrap("`", "`") }
    @objc func cmdTag() { insertAtCursor("#") }
    @objc func cmdDismiss() { resignFirstResponder() }
}

// MARK: - Formatting bar above the keyboard

final class MarkdownAccessoryBar: UIInputView {
    init(textView: MarkdownTextView) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: 46), inputViewStyle: .keyboard)
        autoresizingMask = .flexibleWidth
        let scroll = UIScrollView()
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)
        let items: [(String, String, Selector)] = [
            ("number", "Titre", #selector(MarkdownTextView.cmdHeading)),
            ("bold", "Gras", #selector(MarkdownTextView.cmdBold)),
            ("italic", "Italique", #selector(MarkdownTextView.cmdItalic)),
            ("highlighter", "Surligner", #selector(MarkdownTextView.cmdMark)),
            ("list.bullet", "Liste", #selector(MarkdownTextView.cmdList)),
            ("checklist", "Case à cocher", #selector(MarkdownTextView.cmdTask)),
            ("text.quote", "Citation", #selector(MarkdownTextView.cmdQuote)),
            ("chevron.left.forwardslash.chevron.right", "Code", #selector(MarkdownTextView.cmdCode)),
            ("link", "Lien interne", #selector(MarkdownTextView.cmdLink)),
            ("number.square", "Étiquette", #selector(MarkdownTextView.cmdTag)),
            ("keyboard.chevron.compact.down", "Masquer le clavier", #selector(MarkdownTextView.cmdDismiss)),
        ]
        for (symbol, label, action) in items {
            let button = UIButton(type: .system)
            button.setImage(UIImage(systemName: symbol), for: .normal)
            button.accessibilityLabel = label
            button.addTarget(textView, action: action, for: .touchUpInside)
            button.widthAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(button)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

// MARK: - SwiftUI bridge

struct MarkdownEditor: UIViewRepresentable {
    let controller: NoteEditorController
    var theme: MarkdownTheme
    var writingMode: Bool

    func makeUIView(context: Context) -> MarkdownTextView {
        let view = MarkdownTextView()
        view.delegate = context.coordinator
        view.highlighter.theme = theme
        view.setMarkdown(controller.text)
        view.onOpenLink = { [weak controller] target in controller?.openLink(target) }
        view.onOpenURL = { url in UIApplication.shared.open(url) }
        controller.textView = view
        return view
    }

    func updateUIView(_ view: MarkdownTextView, context: Context) {
        view.applyTheme(theme)
        if view.typewriter != writingMode { view.typewriter = writingMode }
        if view.focusMode != writingMode { view.focusMode = writingMode }
    }

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    final class Coordinator: NSObject, UITextViewDelegate {
        let controller: NoteEditorController

        init(controller: NoteEditorController) { self.controller = controller }

        func textViewDidChange(_ textView: UITextView) {
            guard let view = textView as? MarkdownTextView else { return }
            controller.textDidChange(view.text)
            updateLinkQuery(view)
            view.centerCaretIfNeeded()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard let view = textView as? MarkdownTextView else { return }
            updateLinkQuery(view)
            if view.focusMode { view.refreshFocus() }
            view.centerCaretIfNeeded()
        }

        /// Only touches observed state when the `[[` query actually changes.
        private func updateLinkQuery(_ view: MarkdownTextView) {
            let query = view.currentLinkQuery().map { LinkQuery(text: $0.query, range: $0.range) }
            if controller.linkQuery != query { controller.linkQuery = query }
        }
    }
}

struct LinkQuery: Equatable {
    var text: String
    var range: NSRange
}
