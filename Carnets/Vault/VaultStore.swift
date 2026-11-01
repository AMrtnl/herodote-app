import Foundation
import Observation

// MARK: - VaultStore
// Index of the Markdown vault (Obsidian-compatible) shared by Notes, Écriture and Carnets.

@Observable final class VaultStore {
    static let shared = VaultStore()

    private(set) var rootURL: URL
    private(set) var isExternal: Bool
    private(set) var notes: [VaultNote] = []
    private(set) var folders: [String] = []
    private(set) var projects: [String: WritingProject] = [:]
    private(set) var isScanning = false
    /// Bumped whenever files may have changed outside the editor (sync, rescan).
    private(set) var externalChangeToken = 0

    /// path → paths of notes linking to it
    private(set) var backlinks: [String: [String]] = [:]
    /// path → resolved target paths
    private(set) var outgoing: [String: [String]] = [:]

    @ObservationIgnored private var contents: [String: String] = [:]
    @ObservationIgnored private var byPathLower: [String: String] = [:]
    @ObservationIgnored private var byNameLower: [String: [String]] = [:]
    @ObservationIgnored private let io = DispatchQueue(label: "carnets.vault.io", qos: .utility)

    private static let bookmarkKey = "vault.bookmark"

    private init() {
        let resolved = Self.resolveRoot()
        rootURL = resolved.url
        isExternal = resolved.external
        bootstrap()
        rescan()
    }

    // MARK: Location

    var locationName: String {
        isExternal ? rootURL.lastPathComponent : "Sur cet appareil (Fichiers › Carnets › Coffre)"
    }

    static var localVaultURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Coffre", isDirectory: true)
    }

    private static func resolveRoot() -> (url: URL, external: Bool) {
        if let data = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                if stale, let fresh = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                    UserDefaults.standard.set(fresh, forKey: bookmarkKey)
                }
                return (url, true)
            }
        }
        return (localVaultURL, false)
    }

    /// Uses a folder chosen in Files (iCloud Drive, Nextcloud, Synology Drive, Working Copy…).
    /// If the folder is empty, the current vault is copied into it first.
    func useExternalFolder(_ url: URL) throws {
        guard url.startAccessingSecurityScopedResource() else { throw VaultError.noAccess }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        try switchRoot(to: url)
        UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
        isExternal = true
    }

    func useLocalFolder() throws {
        try switchRoot(to: Self.localVaultURL)
        UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
        isExternal = false
    }

    private func switchRoot(to newRoot: URL) throws {
        NotebookStore.shared.flushAll()
        NotebookStore.shared.waitForPendingWrites()
        io.sync {}
        let fm = FileManager.default
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let existing = (try? fm.contentsOfDirectory(atPath: newRoot.path))?.filter { !$0.hasPrefix(".") } ?? []
        if existing.isEmpty, newRoot.standardizedFileURL != rootURL.standardizedFileURL {
            for name in (try? fm.contentsOfDirectory(atPath: rootURL.path)) ?? [] {
                let source = rootURL.appendingPathComponent(name)
                let target = newRoot.appendingPathComponent(name)
                if !fm.fileExists(atPath: target.path) { try? fm.copyItem(at: source, to: target) }
            }
        }
        rootURL = newRoot
        bootstrap()
        rescan()
        NotebookStore.shared.reload()
    }

    /// Creates the standard folders, a minimal Obsidian config and a welcome note.
    private func bootstrap() {
        let fm = FileManager.default
        let isNew = !fm.fileExists(atPath: rootURL.path)
        for folder in [VaultPaths.carnetsData, VaultPaths.journal, VaultPaths.writing, VaultPaths.attachments] {
            try? fm.createDirectory(at: url(for: folder), withIntermediateDirectories: true)
        }
        let obsidian = url(for: ".obsidian")
        if !fm.fileExists(atPath: obsidian.path) {
            try? fm.createDirectory(at: obsidian, withIntermediateDirectories: true)
            let app = """
            {
              "attachmentFolderPath": "\(VaultPaths.attachments)",
              "alwaysUpdateLinks": true,
              "newLinkFormat": "shortest",
              "userIgnoreFilters": ["\(VaultPaths.carnetsData)/"]
            }
            """
            try? app.write(to: obsidian.appendingPathComponent("app.json"), atomically: true, encoding: .utf8)
            let daily = """
            { "folder": "\(VaultPaths.journal)", "format": "YYYY-MM-DD" }
            """
            try? daily.write(to: obsidian.appendingPathComponent("daily-notes.json"), atomically: true, encoding: .utf8)
        }
        let welcome = url(for: "Bienvenue.md")
        if isNew || (!fm.fileExists(atPath: welcome.path) && !UserDefaults.standard.bool(forKey: "vault.welcomed")) {
            UserDefaults.standard.set(true, forKey: "vault.welcomed")
            try? Self.welcomeNote.write(to: welcome, atomically: true, encoding: .utf8)
        }
    }

    // MARK: Paths

    func url(for path: String) -> URL {
        path.isEmpty ? rootURL : rootURL.appendingPathComponent(path)
    }

    func note(_ path: String) -> VaultNote? {
        notes.first { $0.path == path }
    }

    func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: path).path)
    }

    func notes(inFolder folder: String) -> [VaultNote] {
        notes.filter { $0.folder == folder }
    }

    func subfolders(of folder: String) -> [String] {
        folders.filter { VaultPaths.parent(of: $0) == folder }
    }

    nonisolated struct TagCount: Identifiable, Hashable, Sendable {
        let tag: String
        let count: Int
        var id: String { tag }
    }

    var allTags: [TagCount] {
        var counts: [String: Int] = [:]
        for note in notes { for tag in note.tags { counts[tag, default: 0] += 1 } }
        return counts.map { TagCount(tag: $0.key, count: $0.value) }.sorted { $0.tag < $1.tag }
    }

    // MARK: Reading & scanning

    func text(of path: String) -> String {
        if let cached = contents[path] { return cached }
        return (try? String(contentsOf: url(for: path), encoding: .utf8)) ?? ""
    }

    /// Reads the file from disk, bypassing the cache (used to detect external changes).
    func diskText(of path: String) -> String? {
        try? String(contentsOf: url(for: path), encoding: .utf8)
    }

    func rescan() {
        let root = rootURL
        isScanning = true
        Task {
            let result = await Task.detached(priority: .utility) { VaultScanner.scan(root: root) }.value
            guard root == self.rootURL else { return }
            self.notes = result.notes
            self.contents = result.contents
            self.folders = result.folders
            self.projects = result.projects
            self.rebuildLinkIndex()
            self.isScanning = false
            self.externalChangeToken += 1
        }
    }

    private func rebuildLinkIndex() {
        byPathLower = [:]
        byNameLower = [:]
        for note in notes {
            byPathLower[note.path.lowercased()] = note.path
            byNameLower[note.title.lowercased(), default: []].append(note.path)
        }
        for key in byNameLower.keys {
            byNameLower[key]?.sort { $0.count < $1.count }
        }
        var back: [String: [String]] = [:]
        var out: [String: [String]] = [:]
        for note in notes {
            var targets: [String] = []
            for link in note.links {
                if let target = resolve(link, from: note.path), target != note.path, !targets.contains(target) {
                    targets.append(target)
                    back[target, default: []].append(note.path)
                }
            }
            out[note.path] = targets
        }
        backlinks = back
        outgoing = out
    }

    /// Resolves a `[[link]]` target like Obsidian: path from the vault root, relative path, then file name.
    func resolve(_ rawTarget: String, from source: String? = nil) -> String? {
        let target = rawTarget.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        let lower = target.lowercased()
        let withExt = lower.hasSuffix(".md") ? lower : lower + ".md"
        if let path = byPathLower[withExt] { return path }
        if let source {
            let relative = VaultPaths.join(VaultPaths.parent(of: source), withExt).lowercased()
            if let path = byPathLower[relative] { return path }
        }
        let name = VaultPaths.title(of: withExt)
        return byNameLower[name]?.first
    }

    // MARK: Writing

    /// Saves a note and refreshes its index entry.
    func save(_ text: String, to path: String) {
        contents[path] = text
        let fileURL = url(for: path)
        io.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        }
        let previous = note(path)
        let entry = MarkdownSyntax.makeNote(path: path, text: text, modified: .now,
                                            created: previous?.created ?? .now,
                                            kind: previous?.kind ?? kindFor(path))
        if let index = notes.firstIndex(where: { $0.path == path }) {
            notes[index] = entry
        } else {
            notes.append(entry)
        }
        rebuildLinkIndex()
        SyncCenter.shared.localChangeOccurred()
    }

    /// Writes a file without touching the note index (assets, generated files).
    func writeData(_ data: Data, to path: String) {
        let fileURL = url(for: path)
        io.async {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func waitForWrites() { io.sync {} }

    private func kindFor(_ path: String) -> NoteKind {
        let folder = VaultPaths.parent(of: path)
        if projects[folder] != nil { return .sheet }
        if folder == VaultPaths.journal, VaultScanner.isDailyName(VaultPaths.title(of: path)) { return .daily }
        return .note
    }

    /// A unique, sanitized path for a new note named `title` in `folder`.
    func uniquePath(folder: String, title: String, ext: String = "md") -> String {
        let base = VaultPaths.sanitizedName(title)
        var candidate = VaultPaths.join(folder, "\(base).\(ext)")
        var n = 2
        while exists(candidate) || note(candidate) != nil {
            candidate = VaultPaths.join(folder, "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }

    @discardableResult
    func createNote(in folder: String, title: String = "Sans titre", body: String? = nil) -> String {
        let path = uniquePath(folder: folder, title: title)
        save(body ?? "", to: path)
        return path
    }

    func createFolder(in parent: String, name: String) -> String {
        var path = VaultPaths.join(parent, VaultPaths.sanitizedName(name))
        var n = 2
        while exists(path) { path = VaultPaths.join(parent, "\(VaultPaths.sanitizedName(name)) \(n)"); n += 1 }
        try? FileManager.default.createDirectory(at: url(for: path), withIntermediateDirectories: true)
        if !folders.contains(path) { folders.append(path); folders.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
        SyncCenter.shared.localChangeOccurred()
        return path
    }

    /// Renames a note and rewrites `[[links]]` pointing to it everywhere in the vault.
    @discardableResult
    func renameNote(_ path: String, to newTitle: String) -> String {
        let name = VaultPaths.sanitizedName(newTitle)
        guard name != VaultPaths.title(of: path) else { return path }
        let folder = VaultPaths.parent(of: path)
        var newPath = VaultPaths.join(folder, name + ".md")
        if newPath.lowercased() != path.lowercased() && (exists(newPath) || note(newPath) != nil) {
            newPath = uniquePath(folder: folder, title: name)
        }
        return move(path, to: newPath)
    }

    /// Moves a note to another path, keeping links working.
    @discardableResult
    func move(_ path: String, to newPath: String) -> String {
        io.sync {}
        let fm = FileManager.default
        let source = url(for: path), destination = url(for: newPath)
        try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard (try? fm.moveItem(at: source, to: destination)) != nil else { return path }

        // Rewrite links in referencing notes (resolved against the old index).
        let referencing = backlinks[path] ?? []
        let newLinkName = VaultPaths.title(of: newPath)
        for sourcePath in referencing {
            let text = self.text(of: sourcePath)
            let rewritten = rewriteLinks(in: text, from: sourcePath, oldTarget: path, newName: newLinkName, newPath: newPath)
            if rewritten != text { save(rewritten, to: sourcePath) }
        }
        let text = contents.removeValue(forKey: path) ?? (try? String(contentsOf: destination, encoding: .utf8)) ?? ""
        contents[newPath] = text
        if let index = notes.firstIndex(where: { $0.path == path }) {
            let old = notes[index]
            notes[index] = MarkdownSyntax.makeNote(path: newPath, text: text, modified: .now, created: old.created, kind: kindFor(newPath))
        }
        rebuildLinkIndex()
        SyncCenter.shared.localChangeOccurred()
        return newPath
    }

    private func rewriteLinks(in text: String, from sourcePath: String, oldTarget: String, newName: String, newPath: String) -> String {
        let ns = text as NSString
        var result = text
        let matches = MarkdownSyntax.wikiLink.matches(in: text, range: NSRange(location: 0, length: ns.length))
        for match in matches.reversed() {
            let inner = ns.substring(with: match.range(at: 2))
            let link = MarkdownSyntax.parseLink(inner)
            guard resolve(link.target, from: sourcePath) == oldTarget else { continue }
            let usesPath = link.target.contains("/")
            var replacement = usesPath ? String(newPath.dropLast(3)) : newName
            if let heading = link.heading { replacement += "#" + heading }
            if let bar = inner.firstIndex(of: "|") { replacement += String(inner[bar...]) }
            if let range = Range(match.range(at: 2), in: result) {
                result.replaceSubrange(range, with: replacement)
            }
        }
        return result
    }

    /// Moves a note or folder to the vault's `.trash` folder (like Obsidian).
    func trash(_ path: String) {
        io.sync {}
        let fm = FileManager.default
        let trashURL = url(for: VaultPaths.trash)
        try? fm.createDirectory(at: trashURL, withIntermediateDirectories: true)
        var destination = trashURL.appendingPathComponent(VaultPaths.fileName(of: path))
        var n = 2
        while fm.fileExists(atPath: destination.path) {
            destination = trashURL.appendingPathComponent("\(n) " + VaultPaths.fileName(of: path))
            n += 1
        }
        try? fm.moveItem(at: url(for: path), to: destination)
        notes.removeAll { $0.path == path || $0.path.hasPrefix(path + "/") }
        folders.removeAll { $0 == path || $0.hasPrefix(path + "/") }
        contents = contents.filter { !($0.key == path || $0.key.hasPrefix(path + "/")) }
        projects[path] = nil
        rebuildLinkIndex()
        SyncCenter.shared.localChangeOccurred()
    }

    func renameFolder(_ path: String, to name: String) -> String {
        let newPath = VaultPaths.join(VaultPaths.parent(of: path), VaultPaths.sanitizedName(name))
        guard newPath != path, !exists(newPath) else { return path }
        io.sync {}
        guard (try? FileManager.default.moveItem(at: url(for: path), to: url(for: newPath))) != nil else { return path }
        rescan()
        SyncCenter.shared.localChangeOccurred()
        return newPath
    }

    // MARK: Daily notes

    static func dailyName(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Path of today's note, created from a small template if needed.
    func dailyNote(for date: Date = .now) -> String {
        let path = VaultPaths.join(VaultPaths.journal, Self.dailyName(for: date) + ".md")
        if note(path) == nil && !exists(path) {
            let title = date.formatted(.dateTime.weekday(.wide).day().month(.wide).year().locale(Locale(identifier: "fr_FR")))
            save("# \(title.prefix(1).uppercased() + title.dropFirst())\n\n", to: path)
        }
        return path
    }

    // MARK: Writing projects

    func project(at folder: String) -> WritingProject? { projects[folder] }

    var projectFolders: [String] {
        projects.keys.sorted { (projects[$0]?.title ?? $0).localizedStandardCompare(projects[$1]?.title ?? $1) == .orderedAscending }
    }

    @discardableResult
    func createProject(title: String) -> String {
        let folder = createFolder(in: VaultPaths.writing, name: title)
        var project = WritingProject(title: VaultPaths.title(of: folder))
        let first = createNote(in: folder, title: "Introduction", body: "# Introduction\n\n")
        project.order = [VaultPaths.fileName(of: first)]
        saveProject(project, at: folder)
        reclassify(folder: folder)
        return folder
    }

    /// Turns an existing folder into a writing project.
    func makeProject(from folder: String) {
        guard projects[folder] == nil else { return }
        var project = WritingProject(title: VaultPaths.fileName(of: folder))
        project.order = notes(inFolder: folder).map { VaultPaths.fileName(of: $0.path) }.sorted()
        saveProject(project, at: folder)
        reclassify(folder: folder)
    }

    func saveProject(_ project: WritingProject, at folder: String) {
        projects[folder] = project
        if let data = try? VaultStoreCoding.encoder().encode(project) {
            writeData(data, to: VaultPaths.join(folder, VaultPaths.projectManifest))
        }
        SyncCenter.shared.localChangeOccurred()
    }

    private func reclassify(folder: String) {
        for index in notes.indices where notes[index].folder == folder {
            notes[index].kind = .sheet
        }
    }

    /// Sheets of a project in reading order (unknown files are appended by name).
    func sheets(of folder: String) -> [VaultNote] {
        let inFolder = notes(inFolder: folder)
        let order = projects[folder]?.order ?? []
        let ordered = order.compactMap { name in inFolder.first { VaultPaths.fileName(of: $0.path) == name } }
        let rest = inFolder.filter { !order.contains(VaultPaths.fileName(of: $0.path)) }
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return ordered + rest
    }

    @discardableResult
    func addSheet(to folder: String, title: String = "Nouvelle feuille") -> String {
        let path = createNote(in: folder, title: title, body: "")
        if var project = projects[folder] {
            project.order = sheets(of: folder).map { VaultPaths.fileName(of: $0.path) }
            if !project.order.contains(VaultPaths.fileName(of: path)) { project.order.append(VaultPaths.fileName(of: path)) }
            saveProject(project, at: folder)
        }
        reclassify(folder: folder)
        return path
    }

    func reorderSheets(in folder: String, names: [String]) {
        guard var project = projects[folder] else { return }
        project.order = names
        saveProject(project, at: folder)
    }

    // MARK: Search

    nonisolated struct NoteHit: Identifiable, Sendable {
        let path: String
        let title: String
        let snippet: String
        var id: String { path }
    }

    func search(_ query: String) -> [NoteHit] {
        let needle = LibrarySearch.normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !needle.isEmpty else { return [] }
        var titleHits: [NoteHit] = []
        var bodyHits: [NoteHit] = []
        for note in notes.sorted(by: { $0.modified > $1.modified }) {
            let body = contents[note.path] ?? ""
            if LibrarySearch.normalized(note.title).contains(needle) {
                titleHits.append(NoteHit(path: note.path, title: note.title, snippet: note.excerpt))
            } else if LibrarySearch.normalized(body).contains(needle) {
                bodyHits.append(NoteHit(path: note.path, title: note.title,
                                        snippet: LibrarySearch.snippet(body, around: query)))
            }
        }
        return titleHits + bodyHits
    }

    /// Titles for `[[` autocompletion, best matches first.
    func linkSuggestions(for query: String, limit: Int = 8) -> [VaultNote] {
        let q = LibrarySearch.normalized(query)
        let sorted = notes.sorted { $0.modified > $1.modified }
        guard !q.isEmpty else { return Array(sorted.prefix(limit)) }
        let prefix = sorted.filter { LibrarySearch.normalized($0.title).hasPrefix(q) }
        let contains = sorted.filter { !LibrarySearch.normalized($0.title).hasPrefix(q) && LibrarySearch.normalized($0.title).contains(q) }
        return Array((prefix + contains).prefix(limit))
    }

    // MARK: Welcome note

    private static let welcomeNote = """
    ---
    tags: [carnets]
    ---
    # Bienvenue dans votre coffre

    Ce dossier est un **coffre** : de simples fichiers Markdown, compatibles avec Obsidian.
    Ouvrez-le dans Obsidian, synchronisez-le avec votre serveur (WebDAV, Nextcloud, Syncthing, Git…) : tout reste lisible.

    ## Trois façons d’écrire
    - **Notes** : reliez vos idées avec des liens `[[Titre de la note]]` et des #étiquettes. Les rétroliens apparaissent dans l’inspecteur, et le graphe montre les connexions.
    - **Écriture** : des projets façon Ulysses, avec des feuilles ordonnées, des objectifs de mots et le mode concentration.
    - **Carnets** : l’écriture manuscrite à l’Apple Pencil. Chaque carnet a sa note dans `Carnets/`, avec l’image des pages et le texte reconnu, par exemple [[Bienvenue dans Carnets]].

    ## Pour commencer
    - [ ] Écrire la note du jour (« Aujourd’hui » dans la barre latérale)
    - [ ] Créer un premier projet d’écriture
    - [ ] Relier une note à un carnet manuscrit

    > Astuce : tapez `[[` pour insérer un lien vers une autre note.
    """
}

nonisolated enum VaultError: LocalizedError {
    case noAccess

    var errorDescription: String? {
        switch self {
        case .noAccess: return "Impossible d’accéder à ce dossier."
        }
    }
}
