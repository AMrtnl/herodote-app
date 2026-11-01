import Foundation
import Observation
import Security

// MARK: - Account & credentials

nonisolated struct WebDAVAccount: Codable, Equatable, Sendable {
    /// Folder URL on the server, e.g. https://cloud.example.com/remote.php/dav/files/alex/Coffre/
    var serverURL: String
    var username: String

    var baseURL: URL? {
        var string = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !string.isEmpty else { return nil }
        if !string.hasSuffix("/") { string += "/" }
        return URL(string: string)
    }

    var keychainAccount: String { "\(username)@\(serverURL)" }
}

nonisolated enum Keychain {
    private static let service = "Carnets.WebDAV"

    static func setPassword(_ password: String, account: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func password(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func deletePassword(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - WebDAV client

nonisolated struct RemoteEntry: Sendable {
    let path: String
    let isDirectory: Bool
    let etag: String?
    let size: Int
}

nonisolated enum WebDAVError: LocalizedError {
    case invalidURL
    case http(Int, String)
    case unauthorized

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "L’adresse du serveur n’est pas valide."
        case .unauthorized: return "Identifiant ou mot de passe refusé par le serveur."
        case .http(let code, let path): return "Le serveur a répondu \(code) pour « \(path) »."
        }
    }
}

nonisolated struct WebDAVClient: Sendable {
    let base: URL
    let authorization: String
    let session: URLSession

    init(base: URL, username: String, password: String) {
        self.base = base
        self.authorization = "Basic " + Data("\(username):\(password)".utf8).base64EncodedString()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpMaximumConnectionsPerHost = 4
        self.session = URLSession(configuration: configuration)
    }

    func url(for path: String) -> URL {
        var url = base
        for component in path.split(separator: "/") where !component.isEmpty {
            url.appendPathComponent(String(component))
        }
        return url
    }

    private func request(_ method: String, _ path: String, body: Data? = nil, headers: [String: String] = [:]) -> URLRequest {
        var request = URLRequest(url: url(for: path))
        request.httpMethod = method
        request.setValue(authorization, forHTTPHeaderField: "Authorization")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = body
        return request
    }

    private func check(_ response: URLResponse, path: String, allowed: Set<Int> = []) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw WebDAVError.http(0, path) }
        if http.statusCode == 401 || http.statusCode == 403 { throw WebDAVError.unauthorized }
        guard (200..<300).contains(http.statusCode) || allowed.contains(http.statusCode) else {
            throw WebDAVError.http(http.statusCode, path)
        }
        return http
    }

    /// Lists one folder (Depth: 1). Returns nil when the folder doesn't exist.
    func list(_ path: String) async throws -> [RemoteEntry]? {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getetag/><d:getcontentlength/></d:prop></d:propfind>
        """.utf8)
        let req = request("PROPFIND", path, body: body,
                          headers: ["Depth": "1", "Content-Type": "application/xml; charset=utf-8"])
        let (data, response) = try await session.data(for: req)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        _ = try check(response, path: path, allowed: [207])
        let parser = PropfindParser()
        let entries = parser.parse(data)
        let basePath = base.path(percentEncoded: false)
        let folderPath = path.isEmpty ? "" : path + "/"
        var result: [RemoteEntry] = []
        for entry in entries {
            guard let hrefURL = URL(string: entry.href, relativeTo: base) else { continue }
            var href = hrefURL.path(percentEncoded: false)
            if href.hasPrefix(basePath) { href = String(href.dropFirst(basePath.count)) }
            while href.hasPrefix("/") { href.removeFirst() }
            while href.hasSuffix("/") { href.removeLast() }
            // Skip the folder itself.
            if href == path || href.isEmpty || (href + "/") == folderPath { continue }
            result.append(RemoteEntry(path: href, isDirectory: entry.isCollection, etag: entry.etag, size: entry.size))
        }
        return result
    }

    /// Recursively lists every file under the base folder.
    func listAll() async throws -> [String: RemoteEntry] {
        var files: [String: RemoteEntry] = [:]
        var queue: [String] = [""]
        while let folder = queue.popLast() {
            guard let entries = try await list(folder) else {
                if folder.isEmpty { try await makeCollection("") }
                continue
            }
            for entry in entries where !SyncFilter.isExcluded(entry.path) {
                if entry.isDirectory { queue.append(entry.path) } else { files[entry.path] = entry }
            }
        }
        return files
    }

    func download(_ path: String) async throws -> Data {
        let (data, response) = try await session.data(for: request("GET", path))
        _ = try check(response, path: path)
        return data
    }

    /// Uploads a file and returns the new ETag when the server provides it.
    func upload(_ path: String, data: Data) async throws -> String? {
        let req = request("PUT", path, headers: ["Content-Type": "application/octet-stream"])
        var (_, response) = try await session.upload(for: req, from: data)
        if (response as? HTTPURLResponse)?.statusCode == 409 {
            // Parent folder missing: create it and retry.
            try await makeCollections(for: path)
            (_, response) = try await session.upload(for: req, from: data)
        }
        let http = try check(response, path: path)
        return (http.value(forHTTPHeaderField: "ETag") ?? http.value(forHTTPHeaderField: "OC-ETag"))
    }

    func etag(of path: String) async throws -> String? {
        let body = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:getetag/></d:prop></d:propfind>
        """.utf8)
        let req = request("PROPFIND", path, body: body, headers: ["Depth": "0", "Content-Type": "application/xml; charset=utf-8"])
        let (data, response) = try await session.data(for: req)
        _ = try check(response, path: path, allowed: [207])
        return PropfindParser().parse(data).first?.etag
    }

    func delete(_ path: String) async throws {
        let (_, response) = try await session.data(for: request("DELETE", path))
        _ = try check(response, path: path, allowed: [404])
    }

    func makeCollection(_ path: String) async throws {
        let (_, response) = try await session.data(for: request("MKCOL", path))
        _ = try check(response, path: path, allowed: [405]) // 405 = already exists
    }

    /// Creates every missing parent folder of `path`.
    func makeCollections(for path: String) async throws {
        let parts = path.split(separator: "/").dropLast()
        var current = ""
        for part in parts {
            current = current.isEmpty ? String(part) : current + "/" + part
            try await makeCollection(current)
        }
    }
}

/// Minimal PROPFIND multistatus parser (namespace-aware, prefix-agnostic).
nonisolated final class PropfindParser: NSObject, XMLParserDelegate {
    nonisolated struct Entry {
        var href = ""
        var etag: String?
        var size = 0
        var isCollection = false
    }

    private var entries: [Entry] = []
    private var current: Entry?
    private var text = ""

    func parse(_ data: Data) -> [Entry] {
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = self
        parser.parse()
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        text = ""
        switch elementName {
        case "response": current = Entry()
        case "collection": current?.isCollection = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch elementName {
        case "href": current?.href = value
        case "getetag": current?.etag = value.isEmpty ? nil : value
        case "getcontentlength": current?.size = Int(value) ?? 0
        case "response":
            if let entry = current { entries.append(entry) }
            current = nil
        default: break
        }
        text = ""
    }
}

// MARK: - What gets synced

nonisolated enum SyncFilter {
    static func isExcluded(_ path: String) -> Bool {
        let name = VaultPaths.fileName(of: path)
        if name == ".DS_Store" || name.hasSuffix(".icloud") || name.hasPrefix("._") { return true }
        if path == VaultPaths.trash || path.hasPrefix(VaultPaths.trash + "/") { return true }
        if path.hasPrefix(".git/") || path == ".git" { return true }
        // Obsidian's per-device workspace layout.
        if path.hasPrefix(".obsidian/workspace") { return true }
        return false
    }
}

// MARK: - Sync engine (two-way, last change wins, conflicts kept as copies)

nonisolated struct SyncRecord: Codable, Sendable {
    var localModified: Double
    var localSize: Int
    var etag: String?
}

nonisolated struct SyncState: Codable, Sendable {
    var serverURL: String = ""
    var records: [String: SyncRecord] = [:]
}

nonisolated struct SyncReport: Sendable {
    var uploaded = 0
    var downloaded = 0
    var deletedLocal = 0
    var deletedRemote = 0
    var conflicts: [String] = []

    var summary: String {
        var parts: [String] = []
        if uploaded > 0 { parts.append("\(uploaded) envoyé\(uploaded > 1 ? "s" : "")") }
        if downloaded > 0 { parts.append("\(downloaded) reçu\(downloaded > 1 ? "s" : "")") }
        if deletedLocal + deletedRemote > 0 { parts.append("\(deletedLocal + deletedRemote) supprimé\(deletedLocal + deletedRemote > 1 ? "s" : "")") }
        if !conflicts.isEmpty { parts.append("\(conflicts.count) conflit\(conflicts.count > 1 ? "s" : "") (copies conservées)") }
        return parts.isEmpty ? "Déjà à jour" : parts.joined(separator: ", ")
    }

    var touchedNotebooks: Bool = false
}

actor VaultSyncEngine {
    nonisolated private struct LocalFile {
        let modified: Double
        let size: Int
    }

    func run(root: URL, client: WebDAVClient, state initial: SyncState) async throws -> (SyncState, SyncReport) {
        var state = initial
        if state.serverURL != client.base.absoluteString {
            state = SyncState(serverURL: client.base.absoluteString, records: [:])
        }
        var report = SyncReport()
        let remote = try await client.listAll()
        let local = listLocal(root: root)
        let paths = Set(remote.keys).union(local.keys).union(state.records.keys)
            .filter { !SyncFilter.isExcluded($0) }
            .sorted()

        for path in paths {
            let l = local[path], r = remote[path], record = state.records[path]
            let localChanged = l.map { record == nil || $0.modified != record!.localModified || $0.size != record!.localSize } ?? false
            let remoteChanged = r.map { record == nil || $0.etag != record!.etag || $0.etag == nil } ?? false
            let fileURL = root.appendingPathComponent(path)
            if path.hasPrefix(VaultPaths.carnetsData + "/") && (l != nil || r != nil) && (localChanged || remoteChanged) {
                report.touchedNotebooks = true
            }

            switch (l, r) {
            case let (localFile?, remoteFile?):
                if record == nil {
                    // First sync with both sides present: keep identical files, otherwise keep both.
                    let data = try await client.download(path)
                    if let mine = try? Data(contentsOf: fileURL), mine == data {
                        state.records[path] = SyncRecord(localModified: localFile.modified, localSize: localFile.size, etag: remoteFile.etag)
                    } else {
                        try saveConflictCopy(data, path: path, root: root)
                        report.conflicts.append(path)
                        state.records[path] = try await push(path, client: client, root: root)
                        report.uploaded += 1
                    }
                } else if localChanged && remoteChanged {
                    let data = try await client.download(path)
                    try saveConflictCopy(data, path: path, root: root)
                    report.conflicts.append(path)
                    state.records[path] = try await push(path, client: client, root: root)
                    report.uploaded += 1
                } else if localChanged {
                    state.records[path] = try await push(path, client: client, root: root)
                    report.uploaded += 1
                } else if remoteChanged {
                    state.records[path] = try await pull(path, etag: remoteFile.etag, client: client, root: root)
                    report.downloaded += 1
                }
            case (_?, nil):
                if record != nil && !localChanged {
                    try? FileManager.default.removeItem(at: fileURL)
                    state.records[path] = nil
                    report.deletedLocal += 1
                } else {
                    state.records[path] = try await push(path, client: client, root: root)
                    report.uploaded += 1
                }
            case let (nil, remoteFile?):
                if record != nil && !remoteChanged {
                    try await client.delete(path)
                    state.records[path] = nil
                    report.deletedRemote += 1
                } else {
                    state.records[path] = try await pull(path, etag: remoteFile.etag, client: client, root: root)
                    report.downloaded += 1
                }
            case (nil, nil):
                state.records[path] = nil
            }
        }
        return (state, report)
    }

    private func push(_ path: String, client: WebDAVClient, root: URL) async throws -> SyncRecord {
        let url = root.appendingPathComponent(path)
        let data = try Data(contentsOf: url)
        var etag = try await client.upload(path, data: data)
        if etag == nil { etag = try? await client.etag(of: path) }
        let info = localInfo(url)
        return SyncRecord(localModified: info.modified, localSize: info.size, etag: etag)
    }

    private func pull(_ path: String, etag: String?, client: WebDAVClient, root: URL) async throws -> SyncRecord {
        let data = try await client.download(path)
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        let info = localInfo(url)
        return SyncRecord(localModified: info.modified, localSize: info.size, etag: etag)
    }

    private func saveConflictCopy(_ data: Data, path: String, root: URL) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.dateFormat = "yyyy-MM-dd HH'h'mm"
        let ext = (path as NSString).pathExtension
        let stem = (path as NSString).deletingPathExtension
        let copy = "\(stem) (conflit serveur \(f.string(from: .now)))" + (ext.isEmpty ? "" : ".\(ext)")
        let url = root.appendingPathComponent(copy)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func localInfo(_ url: URL) -> LocalFile {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return LocalFile(modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0, size: values?.fileSize ?? 0)
    }

    private func listLocal(root: URL) -> [String: LocalFile] {
        var result: [String: LocalFile] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else { return result }
        for case let url as URL in enumerator {
            guard let rel = VaultScanner.relativePath(of: url, root: root), !rel.isEmpty else { continue }
            if SyncFilter.isExcluded(rel) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { enumerator.skipDescendants() }
                continue
            }
            let values = try? url.resourceValues(forKeys: Set(keys))
            if values?.isDirectory == true { continue }
            result[rel] = LocalFile(modified: values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
                                    size: values?.fileSize ?? 0)
        }
        return result
    }
}

// MARK: - SyncCenter (state shown in the UI)

@Observable final class SyncCenter {
    static let shared = SyncCenter()

    private(set) var account: WebDAVAccount?
    private(set) var isSyncing = false
    private(set) var lastSync: Date?
    private(set) var lastMessage: String?
    private(set) var lastError: String?
    private(set) var autoSync: Bool

    @ObservationIgnored private let engine = VaultSyncEngine()
    @ObservationIgnored private var debounce: Task<Void, Never>?
    @ObservationIgnored private var state: SyncState
    /// Set by the app while a handwritten notebook is open (its files must not change underneath).
    @ObservationIgnored var isNotebookOpen = false

    private init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "sync.account"),
           let decoded = try? JSONDecoder().decode(WebDAVAccount.self, from: data) {
            account = decoded
        }
        autoSync = (defaults.object(forKey: "sync.auto") as? Bool) ?? true
        lastSync = defaults.object(forKey: "sync.last") as? Date
        state = Self.loadState()
    }

    var isConfigured: Bool { account != nil }

    func setAutoSync(_ enabled: Bool) {
        autoSync = enabled
        UserDefaults.standard.set(enabled, forKey: "sync.auto")
    }

    func configure(serverURL: String, username: String, password: String) {
        let newAccount = WebDAVAccount(serverURL: serverURL, username: username)
        if let old = account, old != newAccount { Keychain.deletePassword(account: old.keychainAccount) }
        Keychain.setPassword(password, account: newAccount.keychainAccount)
        account = newAccount
        if let data = try? JSONEncoder().encode(newAccount) { UserDefaults.standard.set(data, forKey: "sync.account") }
        lastError = nil
    }

    func disconnect() {
        if let account { Keychain.deletePassword(account: account.keychainAccount) }
        account = nil
        UserDefaults.standard.removeObject(forKey: "sync.account")
        state = SyncState()
        saveState()
        lastMessage = nil
        lastError = nil
    }

    /// Called after local edits; syncs a little later.
    func localChangeOccurred() {
        guard autoSync, account != nil else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    func syncNow() async {
        guard let account, let base = account.baseURL, !isSyncing else {
            if account?.baseURL == nil && account != nil { lastError = WebDAVError.invalidURL.localizedDescription }
            return
        }
        guard !isNotebookOpen else {
            lastMessage = "Synchronisation reportée : un carnet est ouvert."
            return
        }
        guard let password = Keychain.password(account: account.keychainAccount) else {
            lastError = "Mot de passe introuvable : reconnectez le serveur."
            return
        }
        isSyncing = true
        lastError = nil
        NotebookStore.shared.flushAll()
        NotebookStore.shared.waitForPendingWrites()
        VaultStore.shared.waitForWrites()
        let client = WebDAVClient(base: base, username: account.username, password: password)
        let root = VaultStore.shared.rootURL
        do {
            let (newState, report) = try await engine.run(root: root, client: client, state: state)
            state = newState
            saveState()
            lastSync = .now
            UserDefaults.standard.set(lastSync, forKey: "sync.last")
            lastMessage = report.summary
            if report.downloaded + report.deletedLocal + report.conflicts.count > 0 {
                VaultStore.shared.rescan()
                if report.touchedNotebooks { NotebookStore.shared.reload() }
            }
        } catch {
            lastError = error.localizedDescription
        }
        isSyncing = false
    }

    private static var stateURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("sync-state.json")
    }

    private static func loadState() -> SyncState {
        guard let data = try? Data(contentsOf: stateURL),
              let state = try? JSONDecoder().decode(SyncState.self, from: data) else { return SyncState() }
        return state
    }

    private func saveState() {
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(state) { try? data.write(to: Self.stateURL, options: .atomic) }
    }
}
