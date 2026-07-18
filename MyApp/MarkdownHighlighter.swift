import AppKit

// MARK: - MarkdownHighlighter
// Idempotent, attribute-only styling pass. The Markdown markers stay in the text
// as real characters; this pass renders their effect live and dims the markers.
// Phase 1 undoes exactly what a previous pass applied (tracked via .herodoteMD),
// so manual formatting, links and comment highlights are never touched, and a
// broken pair un-styles itself on the next pass.

enum MarkdownHighlighter {

    enum Tag: String {
        case marker
        case bold = "b"
        case italic = "i"
        case boldItalic = "bi"
        case strike = "s"
        case h1, h2, h3
    }

    struct Span {
        let markerRanges: [NSRange]
        let contentRange: NSRange
        let tag: Tag
    }

    struct Heading {
        let level: Int
        let title: String
        let range: NSRange
    }

    private static let hashChar: unichar = 35   // '#'
    private static let spaceChar: unichar = 32  // ' '

    // Longest markers first; incomplete pairs simply don't match, so "**gras*"
    // stays inert until the closing "*" arrives.
    private static let inlinePatterns: [(regex: NSRegularExpression, tag: Tag)] = {
        func rx(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern)
        }
        return [
            (rx("(?<!\\*)\\*\\*\\*(?![\\s*])(.+?)(?<![\\s*])\\*\\*\\*(?!\\*)"), .boldItalic),
            (rx("(?<!\\*)\\*\\*(?![\\s*])(.+?)(?<![\\s*])\\*\\*(?!\\*)"),       .bold),
            (rx("(?<!\\*)\\*(?![\\s*])(.+?)(?<![\\s*])\\*(?!\\*)"),             .italic),
            (rx("(?<!~)~~(?![\\s~])(.+?)(?<![\\s~])~~(?!~)"),                   .strike),
        ]
    }()

    // MARK: Public

    /// Re-style every paragraph intersecting `range`. Attribute-only: never mutates characters.
    static func highlight(_ storage: NSMutableAttributedString, in range: NSRange) {
        guard storage.length > 0 else { return }
        let text = storage.string as NSString
        let paragraphs = text.paragraphRange(for: clamp(range, to: storage.length))

        storage.beginEditing()
        reset(storage, in: paragraphs)
        for span in spans(in: text, within: paragraphs) {
            apply(span, to: storage)
        }
        restoreLinkStyling(storage, in: paragraphs)
        storage.endEditing()
    }

    /// Markdown headings (levels 1–3) of a whole text — feeds the outline and quick-open.
    static func headings(in text: String) -> [Heading] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        var out: [Heading] = []
        forEachParagraph(in: ns, within: NSRange(location: 0, length: ns.length)) { para in
            guard para.length > 1 else { return }
            var hashes = 0
            while hashes < para.length, ns.character(at: para.location + hashes) == hashChar { hashes += 1 }
            guard (1...3).contains(hashes),
                  hashes < para.length,
                  ns.character(at: para.location + hashes) == spaceChar,
                  para.length > hashes + 1 else { return }
            let title = ns.substring(with: NSRange(location: para.location + hashes + 1,
                                                   length: para.length - hashes - 1))
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { out.append(Heading(level: hashes, title: title, range: para)) }
        }
        return out
    }

    // MARK: Phase 1 — reset only what we tagged

    private static func reset(_ storage: NSMutableAttributedString, in range: NSRange) {
        var tagged: [NSRange] = []
        storage.enumerateAttribute(.herodoteMD, in: range) { value, r, _ in
            if value != nil { tagged.append(r) }
        }
        guard !tagged.isEmpty else { return }
        let bodyFont = AppSettings.shared.editorFont()
        for r in tagged {
            storage.addAttribute(.font, value: bodyFont, range: r)
            storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: r)
            storage.removeAttribute(.strikethroughStyle, range: r)
            storage.removeAttribute(.herodoteMD, range: r)
        }
    }

    // MARK: Phase 2 — scan

    static func spans(in text: NSString, within range: NSRange) -> [Span] {
        var result: [Span] = []
        forEachParagraph(in: text, within: range) { para in
            result.append(contentsOf: spansInParagraph(text, para))
        }
        return result
    }

    private static func spansInParagraph(_ text: NSString, _ para: NSRange) -> [Span] {
        guard para.length > 0 else { return [] }
        var spans: [Span] = []
        var occupied = IndexSet()
        let paragraph = text.substring(with: para)
        let paragraphNS = paragraph as NSString
        let localFull = NSRange(location: 0, length: paragraphNS.length)

        // Heading prefix "# ", "## ", "### " at line start
        var hashes = 0
        while hashes < paragraphNS.length, paragraphNS.character(at: hashes) == hashChar { hashes += 1 }
        if (1...3).contains(hashes),
           hashes < paragraphNS.length,
           paragraphNS.character(at: hashes) == spaceChar,
           paragraphNS.length > hashes + 1 {
            let tag: Tag = hashes == 1 ? .h1 : (hashes == 2 ? .h2 : .h3)
            let marker = NSRange(location: 0, length: hashes + 1)
            let content = NSRange(location: hashes + 1, length: paragraphNS.length - hashes - 1)
            spans.append(Span(markerRanges: [shift(marker, by: para.location)],
                              contentRange: shift(content, by: para.location),
                              tag: tag))
            occupied.insert(integersIn: 0..<(hashes + 1))
        }

        // Inline spans. Occupied indices stop marker characters from being reused
        // as markers; content ranges may nest (e.g. italic inside bold).
        for (regex, tag) in inlinePatterns {
            for match in regex.matches(in: paragraph, range: localFull) {
                let full = match.range
                let content = match.range(at: 1)
                let lead = NSRange(location: full.location, length: content.location - full.location)
                let trail = NSRange(location: NSMaxRange(content), length: NSMaxRange(full) - NSMaxRange(content))
                if occupied.intersects(integersIn: lead.location..<NSMaxRange(lead)) ||
                   occupied.intersects(integersIn: trail.location..<NSMaxRange(trail)) { continue }
                occupied.insert(integersIn: lead.location..<NSMaxRange(lead))
                occupied.insert(integersIn: trail.location..<NSMaxRange(trail))
                spans.append(Span(markerRanges: [shift(lead, by: para.location), shift(trail, by: para.location)],
                                  contentRange: shift(content, by: para.location),
                                  tag: tag))
            }
        }
        return spans
    }

    // MARK: Phase 2 — apply

    private static func apply(_ span: Span, to storage: NSMutableAttributedString) {
        let settings = AppSettings.shared
        switch span.tag {
        case .h1:  applyTraits([.bold], size: settings.fontSize + 12, to: storage, in: span.contentRange)
        case .h2:  applyTraits([.bold], size: settings.fontSize + 6,  to: storage, in: span.contentRange)
        case .h3:  applyTraits([.bold], size: settings.fontSize + 2,  to: storage, in: span.contentRange)
        case .bold:       applyTraits([.bold],            to: storage, in: span.contentRange)
        case .italic:     applyTraits([.italic],          to: storage, in: span.contentRange)
        case .boldItalic: applyTraits([.bold, .italic],   to: storage, in: span.contentRange)
        case .strike:
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: span.contentRange)
        case .marker:
            break
        }
        storage.addAttribute(.herodoteMD, value: span.tag.rawValue, range: span.contentRange)

        let markerFont = settings.editorFont(size: max(9, settings.fontSize * 0.75))
        for r in span.markerRanges {
            storage.addAttribute(.font, value: markerFont, range: r)
            storage.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: r)
            storage.addAttribute(.herodoteMD, value: Tag.marker.rawValue, range: r)
        }
    }

    private static func applyTraits(_ traits: NSFontDescriptor.SymbolicTraits,
                                    size: Double? = nil,
                                    to storage: NSMutableAttributedString,
                                    in range: NSRange) {
        storage.enumerateAttribute(.font, in: range) { value, r, _ in
            let base = value as? NSFont ?? AppSettings.shared.editorFont()
            let pointSize = size ?? Double(base.pointSize)
            let descriptor = base.fontDescriptor
                .withSymbolicTraits(base.fontDescriptor.symbolicTraits.union(traits))
            let font = NSFont(descriptor: descriptor, size: pointSize) ?? base
            storage.addAttribute(.font, value: font, range: r)
        }
    }

    // The uniform reset repaints tagged ranges in labelColor; links inside a
    // styled span get their look back here.
    private static func restoreLinkStyling(_ storage: NSMutableAttributedString, in range: NSRange) {
        storage.enumerateAttribute(.link, in: range) { value, r, _ in
            guard value != nil else { return }
            storage.addAttribute(.foregroundColor, value: NSColor.linkColor, range: r)
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: r)
        }
    }

    // MARK: Helpers

    private static func forEachParagraph(in text: NSString, within range: NSRange, _ body: (NSRange) -> Void) {
        var loc = range.location
        let limit = NSMaxRange(range)
        while loc < limit {
            var start = 0, end = 0, contentsEnd = 0
            text.getParagraphStart(&start, end: &end, contentsEnd: &contentsEnd,
                                   for: NSRange(location: loc, length: 0))
            body(NSRange(location: start, length: contentsEnd - start))
            if end <= loc { break }
            loc = end
        }
    }

    private static func clamp(_ range: NSRange, to length: Int) -> NSRange {
        let loc = min(max(0, range.location), length)
        return NSRange(location: loc, length: min(range.length, length - loc))
    }

    private static func shift(_ range: NSRange, by offset: Int) -> NSRange {
        NSRange(location: range.location + offset, length: range.length)
    }
}
