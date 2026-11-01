import UIKit

// MARK: - MarkdownExporter (notes and assembled writing projects → PDF, Markdown, HTML)

enum MarkdownExporter {
    enum Format { case pdf, markdown, html }

    static func export(title: String, markdown: String, format: Format) -> URL? {
        let body = MarkdownSyntax.parseFrontmatter(markdown).body
        let directory = FileManager.default.temporaryDirectory
        switch format {
        case .markdown:
            let url = directory.appendingPathComponent(PageRenderer.exportFileName(title, ext: "md"))
            return (try? markdown.write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
        case .html:
            let url = directory.appendingPathComponent(PageRenderer.exportFileName(title, ext: "html"))
            return (try? html(body, title: title).write(to: url, atomically: true, encoding: .utf8)) != nil ? url : nil
        case .pdf:
            let url = directory.appendingPathComponent(PageRenderer.exportFileName(title, ext: "pdf"))
            return (try? pdf(attributed(body)).write(to: url, options: .atomic)) != nil ? url : nil
        }
    }

    // MARK: Blocks

    private enum Block {
        case heading(Int, String)
        case paragraph(String)
        case bullet(String, Int)
        case task(String, Bool)
        case quote(String)
        case code(String)
        case rule
    }

    private static func blocks(_ markdown: String) -> [Block] {
        var result: [Block] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { result.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
        }
        for raw in markdown.components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if let lines = code { result.append(.code(lines.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
                continue
            }
            if code != nil { code?.append(line); continue }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { flush(); continue }
            if trimmed.hasPrefix("<!--") { continue }
            if trimmed.hasPrefix("#"), let space = trimmed.firstIndex(of: " "), trimmed[..<space].allSatisfy({ $0 == "#" }) {
                flush()
                result.append(.heading(min(6, trimmed.distance(from: trimmed.startIndex, to: space)), String(trimmed[space...]).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.range(of: #"^[-*+] \[[ xX]\] "#, options: .regularExpression) != nil {
                flush()
                let done = trimmed.dropFirst(3).first.map { $0 == "x" || $0 == "X" } ?? false
                result.append(.task(String(trimmed.dropFirst(6)), done))
            } else if trimmed.range(of: #"^([-*+]|\d+[.)]) "#, options: .regularExpression) != nil {
                flush()
                let indent = line.prefix(while: { $0 == " " || $0 == "\t" }).count / 2
                let text = trimmed.replacingOccurrences(of: #"^([-*+]|\d+[.)]) "#, with: "", options: .regularExpression)
                result.append(.bullet(text, indent))
            } else if trimmed.hasPrefix(">") {
                flush()
                result.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if trimmed.range(of: #"^([-*_])( *\1){2,}$"#, options: .regularExpression) != nil {
                flush()
                result.append(.rule)
            } else if trimmed.hasPrefix("![") {
                continue
            } else {
                paragraph.append(trimmed)
            }
        }
        flush()
        if let lines = code { result.append(.code(lines.joined(separator: "\n"))) }
        return result
    }

    /// Replaces Obsidian-only syntax with plain text.
    private static func simplifyInline(_ text: String) -> String {
        var s = text
        s = s.replacingOccurrences(of: #"!?\[\[([^\]|]+)\|([^\]]+)\]\]"#, with: "$2", options: .regularExpression)
        s = s.replacingOccurrences(of: #"!?\[\[([^\]#|]+)(#[^\]]*)?\]\]"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: #"==([^=]+)=="#, with: "$1", options: .regularExpression)
        return s
    }

    // MARK: Attributed (PDF)

    static func attributed(_ markdown: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let bodySize: CGFloat = 12
        func serif(_ size: CGFloat, _ weight: UIFont.Weight = .regular) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(.serif).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        func paragraphStyle(spacingBefore: CGFloat = 0, after: CGFloat = 8, indent: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineHeightMultiple = 1.25
            p.paragraphSpacingBefore = spacingBefore
            p.paragraphSpacing = after
            p.firstLineHeadIndent = indent
            p.headIndent = indent
            return p
        }
        func appendInline(_ text: String, font: UIFont, color: UIColor = .black, style: NSParagraphStyle) {
            let source = simplifyInline(text)
            let parsed = (try? AttributedString(markdown: source, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(source)
            for run in parsed.runs {
                var runFont = font
                var attributes: [NSAttributedString.Key: Any] = [.foregroundColor: color, .paragraphStyle: style]
                if let intent = run.inlinePresentationIntent {
                    var traits = runFont.fontDescriptor.symbolicTraits
                    if intent.contains(.stronglyEmphasized) { traits.insert(.traitBold) }
                    if intent.contains(.emphasized) { traits.insert(.traitItalic) }
                    if let descriptor = runFont.fontDescriptor.withSymbolicTraits(traits) {
                        runFont = UIFont(descriptor: descriptor, size: runFont.pointSize)
                    }
                    if intent.contains(.code) { runFont = UIFont.monospacedSystemFont(ofSize: font.pointSize * 0.9, weight: .regular) }
                    if intent.contains(.strikethrough) { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
                }
                if let link = run.link { attributes[.link] = link }
                attributes[.font] = runFont
                out.append(NSAttributedString(string: String(parsed[run.range].characters), attributes: attributes))
            }
            out.append(NSAttributedString(string: "\n", attributes: [.font: font, .paragraphStyle: style]))
        }
        for block in blocks(markdown) {
            switch block {
            case .heading(let level, let text):
                let sizes: [CGFloat] = [24, 19, 16, 14, 13, 12]
                appendInline(text, font: serif(sizes[level - 1], .bold),
                             style: paragraphStyle(spacingBefore: level <= 2 ? 14 : 8, after: 6))
            case .paragraph(let text):
                appendInline(text, font: serif(bodySize), style: paragraphStyle())
            case .bullet(let text, let indent):
                appendInline("•  " + text, font: serif(bodySize), style: paragraphStyle(after: 3, indent: 14 + CGFloat(indent) * 14))
            case .task(let text, let done):
                appendInline((done ? "☑︎  " : "☐  ") + text, font: serif(bodySize), style: paragraphStyle(after: 3, indent: 14))
            case .quote(let text):
                appendInline(text, font: serif(bodySize).withItalic(), color: .darkGray, style: paragraphStyle(indent: 18))
            case .code(let text):
                let style = paragraphStyle(after: 10, indent: 12)
                out.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: UIColor.darkGray, .paragraphStyle: style,
                ]))
            case .rule:
                out.append(NSAttributedString(string: "⁂\n", attributes: [
                    .font: serif(bodySize), .paragraphStyle: { let p = NSMutableParagraphStyle(); p.alignment = .center; p.paragraphSpacing = 10; return p }(),
                ]))
            }
        }
        return out
    }

    static func pdf(_ text: NSAttributedString) -> Data {
        let paper = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        let printable = paper.insetBy(dx: 64, dy: 72)
        let formatter = UISimpleTextPrintFormatter(attributedText: text)
        let renderer = UIPrintPageRenderer()
        renderer.addPrintFormatter(formatter, startingAtPageAt: 0)
        renderer.setValue(NSValue(cgRect: paper), forKey: "paperRect")
        renderer.setValue(NSValue(cgRect: printable), forKey: "printableRect")
        let data = NSMutableData()
        UIGraphicsBeginPDFContextToData(data, paper, nil)
        renderer.prepare(forDrawingPages: NSRange(location: 0, length: renderer.numberOfPages))
        for page in 0..<renderer.numberOfPages {
            UIGraphicsBeginPDFPage()
            renderer.drawPage(at: page, in: UIGraphicsGetPDFContextBounds())
        }
        UIGraphicsEndPDFContext()
        return data as Data
    }

    // MARK: HTML

    static func html(_ markdown: String, title: String) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
        }
        func inline(_ s: String) -> String {
            var t = escape(simplifyInline(s))
            t = t.replacingOccurrences(of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"(?<!\*)\*(?!\*)(.+?)\*"#, with: "<em>$1</em>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"~~(.+?)~~"#, with: "<del>$1</del>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
            return t
        }
        var body: [String] = []
        var inList = false
        for block in blocks(markdown) {
            if case .bullet = block {} else if case .task = block {} else if inList { body.append("</ul>"); inList = false }
            switch block {
            case .heading(let level, let text): body.append("<h\(level)>\(inline(text))</h\(level)>")
            case .paragraph(let text): body.append("<p>\(inline(text))</p>")
            case .bullet(let text, _):
                if !inList { body.append("<ul>"); inList = true }
                body.append("<li>\(inline(text))</li>")
            case .task(let text, let done):
                if !inList { body.append("<ul class=\"tasks\">"); inList = true }
                body.append("<li><input type=\"checkbox\" disabled\(done ? " checked" : "")> \(inline(text))</li>")
            case .quote(let text): body.append("<blockquote>\(inline(text))</blockquote>")
            case .code(let text): body.append("<pre><code>\(escape(text))</code></pre>")
            case .rule: body.append("<hr>")
            }
        }
        if inList { body.append("</ul>") }
        return """
        <!doctype html>
        <html lang="fr"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        body { font: 18px/1.6 "New York", Georgia, serif; max-width: 42em; margin: 3em auto; padding: 0 1.2em; color: #1c1c1e; }
        h1, h2, h3 { line-height: 1.25; } code, pre { font: 0.85em ui-monospace, Menlo, monospace; background: #f2f2f7; }
        pre { padding: 1em; overflow-x: auto; border-radius: 8px; } blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid #d9582e; color: #555; }
        ul.tasks { list-style: none; padding-left: 0.4em; } hr { border: 0; text-align: center; } hr::after { content: "⁂"; color: #888; }
        @media (prefers-color-scheme: dark) { body { background: #111; color: #eee; } code, pre { background: #222; } }
        </style></head><body>
        \(body.joined(separator: "\n"))
        </body></html>
        """
    }
}

private extension UIFont {
    func withItalic() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic)) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
