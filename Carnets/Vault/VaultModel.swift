import Foundation

// MARK: - Vault layout
//
// The vault is a plain folder of Markdown files, compatible with Obsidian:
//
//   <Vault>/
//     .obsidian/                 created only if missing (Obsidian settings)
//     Bienvenue.md               any notes and folders you like
//     Journal/2026-11-01.md      daily notes
//     Écriture/<Projet>/         writing projects: ordered sheets + projet.json
//     Carnets/<Titre>.md         one note per handwritten notebook (page images + recognised text)
//     Carnets/Données/<uuid>/    handwritten notebook data (ink, PDFs, page renders)
//     Pièces jointes/            images pasted into notes
//     .trash/                    deleted notes (same convention as Obsidian)

nonisolated enum VaultPaths {
    static let carnets = "Carnets"
    static let carnetsData = "Carnets/Données"
    static let journal = "Journal"
    static let writing = "Écriture"
    static let attachments = "Pièces jointes"
    static let trash = ".trash"
    static let projectManifest = "projet.json"

    /// Folders that never appear as note folders.
    static func isHidden(_ relativePath: String) -> Bool {
        relativePath.hasPrefix(".") || relativePath.contains("/.")
            || relativePath == carnetsData || relativePath.hasPrefix(carnetsData + "/")
    }

    static func join(_ folder: String, _ name: String) -> String {
        folder.isEmpty ? name : folder + "/" + name
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }

    static func fileName(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        return String(path[path.index(after: slash)...])
    }

    static func title(of path: String) -> String {
        let name = fileName(of: path)
        return name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name
    }

    /// Characters Obsidian and most file systems refuse in note names.
    static func sanitizedName(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|#^[]")
        let cleaned = title.components(separatedBy: invalid).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Sans titre" : String(cleaned.prefix(120))
    }
}

// MARK: - Notes

nonisolated enum NoteKind: String, Codable, Sendable {
    case note, daily, notebook, sheet
}

nonisolated struct VaultNote: Identifiable, Hashable, Sendable {
    /// Vault-relative path, e.g. "Projets/Idées.md".
    let path: String
    var title: String
    var folder: String
    var modified: Date
    var created: Date
    /// Raw `[[wikilink]]` targets (alias, heading and block parts removed).
    var links: [String]
    /// Lower-cased tags without '#', from the body and the `tags` property.
    var tags: [String]
    var properties: [String: String]
    var wordCount: Int
    var excerpt: String
    var kind: NoteKind

    var id: String { path }

    /// Notebook id for the companion note of a handwritten notebook.
    var notebookID: UUID? { properties["carnets-id"].flatMap(UUID.init(uuidString:)) }
}

// MARK: - Writing projects (Ulysses-style)

nonisolated struct WritingProject: Codable, Equatable, Sendable {
    var title: String
    /// Sheet file names in reading order.
    var order: [String] = []
    /// Word goal for the whole project.
    var goal: Int? = nil
    var deadline: Date? = nil
    /// Per-sheet word goals, keyed by file name.
    var sheetGoals: [String: Int] = [:]
    var created: Date = .now

    init(title: String) { self.title = title }

    nonisolated enum CodingKeys: String, CodingKey {
        case title, order, goal, deadline, sheetGoals, created
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = c.value(.title, default: "Projet")
        order = c.value(.order, default: [])
        goal = c.value(.goal, default: Optional<Int>.none)
        deadline = c.value(.deadline, default: Optional<Date>.none)
        sheetGoals = c.value(.sheetGoals, default: [:])
        created = c.value(.created, default: Date.now)
    }
}

// MARK: - Markdown parsing (thread-safe)

nonisolated enum MarkdownSyntax {
    static let wikiLink = try! NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]+?)\]\]"#)
    static let tag = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}_/#&\]\)])#([\p{L}_][\p{L}\p{N}_/\-]*)"#)
    static let codeFence = try! NSRegularExpression(
        pattern: #"^(```|~~~)[^\n]*\n[\s\S]*?(^\1[ \t]*$|\z)"#, options: [.anchorsMatchLines])
    static let inlineCode = try! NSRegularExpression(pattern: #"`[^`\n]+`"#)

    /// Range of the YAML front matter block (including the `---` lines), if any.
    static func frontmatterRange(in text: NSString) -> NSRange? {
        guard text.hasPrefix("---\n") || text.hasPrefix("---\r\n") else { return nil }
        let search = NSRange(location: 3, length: text.length - 3)
        let end = text.range(of: "\n---", options: [], range: search)
        guard end.location != NSNotFound else { return nil }
        var length = end.location + end.length
        // include the line break after the closing fence
        if length < text.length, text.character(at: length) == 10 { length += 1 }
        return NSRange(location: 0, length: length)
    }

    /// Very small YAML subset: `key: value`, `key: [a, b]` and `key:` followed by `- item` lines.
    static func parseFrontmatter(_ text: String) -> (properties: [String: String], tags: [String], body: String) {
        let ns = text as NSString
        guard let range = frontmatterRange(in: ns) else { return ([:], [], text) }
        let block = ns.substring(with: NSRange(location: 4, length: max(0, range.length - 4)))
        var properties: [String: String] = [:]
        var tags: [String] = []
        var currentKey: String?
        var listValues: [String] = []

        func flush() {
            guard let key = currentKey, !listValues.isEmpty else { return }
            properties[key] = listValues.joined(separator: ", ")
            if key == "tags" || key == "tag" { tags += listValues }
            listValues = []
        }

        for rawLine in block.components(separatedBy: "\n") {
            let line = rawLine.replacingOccurrences(of: "\r", with: "")
            if line.hasPrefix("---") { break }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("- "), currentKey != nil {
                listValues.append(unquote(String(trimmed.dropFirst(2))))
                continue
            }
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            flush()
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            currentKey = key
            if value.hasPrefix("[") && value.hasSuffix("]") {
                value = String(value.dropFirst().dropLast())
                let items = value.split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }
                properties[key] = items.joined(separator: ", ")
                if key == "tags" || key == "tag" { tags += items }
            } else if !value.isEmpty {
                properties[key] = unquote(value)
                if key == "tags" || key == "tag" {
                    tags += value.split(whereSeparator: { $0 == "," || $0 == " " }).map { unquote(String($0)) }
                }
            }
        }
        flush()
        let body = ns.substring(from: range.location + range.length)
        let cleanTags = tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).lowercased() }.filter { !$0.isEmpty }
        return (properties, cleanTags, body)
    }

    private static func unquote(_ s: String) -> String {
        var v = s.trimmingCharacters(in: .whitespaces)
        if v.count >= 2, (v.hasPrefix("\"") && v.hasSuffix("\"")) || (v.hasPrefix("'") && v.hasSuffix("'")) {
            v = String(v.dropFirst().dropLast())
        }
        return v
    }

    /// Splits the inside of `[[…]]` into target, heading and display text.
    static func parseLink(_ inner: String) -> (target: String, heading: String?, display: String) {
        var target = inner
        var display = inner
        if let bar = inner.firstIndex(of: "|") {
            target = String(inner[..<bar])
            display = String(inner[inner.index(after: bar)...])
        }
        var heading: String?
        if let hash = target.firstIndex(of: "#") {
            heading = String(target[target.index(after: hash)...])
            target = String(target[..<hash])
            if display == inner { display = target.isEmpty ? (heading ?? inner) : target }
        } else if display == inner {
            display = target
        }
        return (target.trimmingCharacters(in: .whitespaces), heading, display.trimmingCharacters(in: .whitespaces))
    }

    /// Ranges covered by code (fenced blocks and inline code) where links and tags don't apply.
    static func codeRanges(in text: NSString) -> [NSRange] {
        let full = NSRange(location: 0, length: text.length)
        var ranges = codeFence.matches(in: text as String, range: full).map(\.range)
        ranges += inlineCode.matches(in: text as String, range: full).map(\.range)
        return ranges
    }

    static func isInside(_ range: NSRange, _ ranges: [NSRange]) -> Bool {
        ranges.contains { NSLocationInRange(range.location, $0) }
    }

    static func wikiTargets(in body: String) -> [String] {
        let ns = body as NSString
        let code = codeRanges(in: ns)
        var targets: [String] = []
        for match in wikiLink.matches(in: body, range: NSRange(location: 0, length: ns.length)) where !isInside(match.range, code) {
            let target = parseLink(ns.substring(with: match.range(at: 2))).target
            if !target.isEmpty && !targets.contains(target) { targets.append(target) }
        }
        return targets
    }

    static func tags(in body: String) -> [String] {
        let ns = body as NSString
        let code = codeRanges(in: ns)
        var result: [String] = []
        for match in tag.matches(in: body, range: NSRange(location: 0, length: ns.length)) where !isInside(match.range, code) {
            let value = ns.substring(with: match.range(at: 1)).lowercased()
            if value.rangeOfCharacter(from: .letters) != nil && !result.contains(value) { result.append(value) }
        }
        return result
    }

    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// First meaningful line(s) of the body, without Markdown markers.
    static func excerpt(_ body: String) -> String {
        var parts: [String] = []
        for line in body.components(separatedBy: "\n") {
            var t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty || t.hasPrefix("```") || t.hasPrefix("![") || t.hasPrefix("<!--") || t == "---" { continue }
            while t.hasPrefix("#") || t.hasPrefix(">") || t.hasPrefix("- ") || t.hasPrefix("* ") {
                t = String(t.drop(while: { "#>-* ".contains($0) }))
            }
            t = t.replacingOccurrences(of: "[[", with: "").replacingOccurrences(of: "]]", with: "")
                .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "==", with: "")
            if !t.isEmpty { parts.append(t) }
            if parts.joined(separator: " ").count > 160 { break }
        }
        return String(parts.joined(separator: " ").prefix(180))
    }

    /// Builds the index entry for a note.
    static func makeNote(path: String, text: String, modified: Date, created: Date, kind: NoteKind) -> VaultNote {
        let parsed = parseFrontmatter(text)
        var tags = parsed.tags
        for tag in self.tags(in: parsed.body) where !tags.contains(tag) { tags.append(tag) }
        return VaultNote(path: path,
                         title: VaultPaths.title(of: path),
                         folder: VaultPaths.parent(of: path),
                         modified: modified,
                         created: created,
                         links: wikiTargets(in: parsed.body),
                         tags: tags,
                         properties: parsed.properties,
                         wordCount: wordCount(parsed.body),
                         excerpt: excerpt(parsed.body),
                         kind: parsed.properties["carnets-id"] != nil ? .notebook : kind)
    }
}

// MARK: - Scanning the vault on disk

nonisolated struct VaultScanResult: Sendable {
    var notes: [VaultNote] = []
    var contents: [String: String] = [:]
    var folders: [String] = []
    var projects: [String: WritingProject] = [:]
}

nonisolated enum VaultScanner {
    static func relativePath(of url: URL, root: URL) -> String? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path
        let full = url.resolvingSymlinksInPath().standardizedFileURL.path
        guard full.hasPrefix(base) else { return nil }
        var rel = String(full.dropFirst(base.count))
        while rel.hasPrefix("/") { rel.removeFirst() }
        return rel
    }

    static func scan(root: URL) -> VaultScanResult {
        var result = VaultScanResult()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .creationDateKey]
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: keys,
                                             options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return result }
        var markdown: [(String, URL, Date, Date)] = []
        for case let url as URL in enumerator {
            guard let rel = relativePath(of: url, root: root), !rel.isEmpty else { continue }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true {
                if VaultPaths.isHidden(rel) { enumerator.skipDescendants(); continue }
                result.folders.append(rel)
                continue
            }
            if VaultPaths.isHidden(rel) { continue }
            let name = url.lastPathComponent
            if name == VaultPaths.projectManifest {
                if let data = try? Data(contentsOf: url),
                   let project = try? VaultStoreCoding.decoder().decode(WritingProject.self, from: data) {
                    result.projects[VaultPaths.parent(of: rel)] = project
                }
                continue
            }
            guard name.lowercased().hasSuffix(".md") else { continue }
            let modified = values?.contentModificationDate ?? .distantPast
            markdown.append((rel, url, modified, values?.creationDate ?? modified))
        }
        for (rel, url, modified, created) in markdown {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            let folder = VaultPaths.parent(of: rel)
            let kind: NoteKind
            if result.projects[folder] != nil {
                kind = .sheet
            } else if folder == VaultPaths.journal, isDailyName(VaultPaths.title(of: rel)) {
                kind = .daily
            } else {
                kind = .note
            }
            result.notes.append(MarkdownSyntax.makeNote(path: rel, text: text, modified: modified, created: created, kind: kind))
            result.contents[rel] = text
        }
        result.folders.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        return result
    }

    static func isDailyName(_ name: String) -> Bool {
        name.count == 10 && name.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }
}

nonisolated enum VaultStoreCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
