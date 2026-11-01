import Foundation
import PDFKit

// MARK: - ZipArchive (read-only; stored and deflated entries, as produced by iOS, macOS and GoodNotes)

nonisolated enum ZipError: LocalizedError {
    case notAZip, unsupported, corrupted

    var errorDescription: String? {
        switch self {
        case .notAZip:     return "Ce fichier n’est pas une archive ZIP."
        case .unsupported: return "Cette archive ZIP utilise un format non pris en charge (ZIP64 ou chiffrement)."
        case .corrupted:   return "L’archive ZIP est endommagée."
        }
    }
}

nonisolated enum ZipArchive {
    nonisolated struct Entry {
        let path: String
        let method: UInt16
        let flags: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        let localHeaderOffset: Int
        var isDirectory: Bool { path.hasSuffix("/") }
    }

    private static func u16(_ d: Data, _ o: Int) -> UInt16 {
        let i = d.startIndex + o
        return UInt16(d[i]) | UInt16(d[i + 1]) << 8
    }

    private static func u32(_ d: Data, _ o: Int) -> UInt32 {
        let i = d.startIndex + o
        return UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }

    static func entries(in data: Data) throws -> [Entry] {
        guard data.count >= 22 else { throw ZipError.notAZip }
        // End of central directory record: scan backwards (comment can be up to 64 KB).
        var eocd = -1
        let lowest = max(0, data.count - 22 - 65_535)
        var o = data.count - 22
        while o >= lowest {
            if u32(data, o) == 0x0605_4b50 { eocd = o; break }
            o -= 1
        }
        guard eocd >= 0 else { throw ZipError.notAZip }
        let count = Int(u16(data, eocd + 10))
        let directoryOffset = u32(data, eocd + 16)
        guard directoryOffset != 0xFFFF_FFFF, count != 0xFFFF else { throw ZipError.unsupported }
        var entries: [Entry] = []
        var p = Int(directoryOffset)
        for _ in 0..<count {
            guard p + 46 <= data.count, u32(data, p) == 0x0201_4b50 else { throw ZipError.corrupted }
            let flags = u16(data, p + 8)
            let method = u16(data, p + 10)
            let compressed = u32(data, p + 20)
            let uncompressed = u32(data, p + 24)
            let nameLength = Int(u16(data, p + 28))
            let extraLength = Int(u16(data, p + 30))
            let commentLength = Int(u16(data, p + 32))
            let localOffset = u32(data, p + 42)
            guard compressed != 0xFFFF_FFFF, localOffset != 0xFFFF_FFFF else { throw ZipError.unsupported }
            guard p + 46 + nameLength <= data.count else { throw ZipError.corrupted }
            let nameData = data.subdata(in: (data.startIndex + p + 46)..<(data.startIndex + p + 46 + nameLength))
            let name = String(data: nameData, encoding: .utf8) ?? String(data: nameData, encoding: .isoLatin1) ?? ""
            entries.append(Entry(path: name, method: method, flags: flags, compressedSize: Int(compressed),
                                 uncompressedSize: Int(uncompressed), localHeaderOffset: Int(localOffset)))
            p += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    static func extract(_ entry: Entry, from data: Data) throws -> Data {
        if entry.flags & 0x1 != 0 { throw ZipError.unsupported } // encrypted
        let o = entry.localHeaderOffset
        guard o + 30 <= data.count, u32(data, o) == 0x0403_4b50 else { throw ZipError.corrupted }
        let start = o + 30 + Int(u16(data, o + 26)) + Int(u16(data, o + 28))
        guard start + entry.compressedSize <= data.count else { throw ZipError.corrupted }
        let payload = data.subdata(in: (data.startIndex + start)..<(data.startIndex + start + entry.compressedSize))
        switch entry.method {
        case 0:
            return payload
        case 8:
            // Apple's "zlib" algorithm is raw DEFLATE (RFC 1951), exactly what ZIP stores.
            return try (payload as NSData).decompressed(using: .zlib) as Data
        default:
            throw ZipError.unsupported
        }
    }

    /// Extracts every file to `directory` and returns their relative paths.
    /// Ignores macOS metadata and refuses paths escaping the destination.
    @discardableResult
    static func extractAll(from url: URL, to directory: URL, extensions: Set<String>? = nil) throws -> [String] {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let fm = FileManager.default
        var written: [String] = []
        for entry in try entries(in: data) where !entry.isDirectory {
            let parts = entry.path.split(separator: "/").map(String.init)
                .filter { !$0.isEmpty && $0 != "." && $0 != ".." }
            guard let last = parts.last, !parts.contains("__MACOSX"), !last.hasPrefix("._"), last != ".DS_Store" else { continue }
            if let wanted = extensions, !wanted.contains((last as NSString).pathExtension.lowercased()) { continue }
            let relative = parts.joined(separator: "/")
            let target = directory.appendingPathComponent(relative)
            // One damaged entry shouldn't make the rest of the archive unreadable.
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try extract(entry, from: data).write(to: target, options: .atomic)
                written.append(relative)
            } catch {
                continue
            }
        }
        return written
    }
}

// MARK: - GoodNotes exports

nonisolated struct ImportCandidate: Sendable {
    nonisolated enum Kind: Sendable { case pdf, goodNotesPackage, notDownloaded }

    /// A readable local file (original, or extracted from an archive).
    let url: URL
    let title: String
    /// Folder names from the export, outermost first (e.g. ["Cours", "Philosophie"]).
    let folderPath: [String]
    let kind: Kind
}

nonisolated enum GoodNotesImporter {
    /// Turns what the user picked (PDFs, ZIP archives, folders, .goodnotes files) into notebooks to import.
    static func candidates(from url: URL, workDirectory: URL) throws -> [ImportCandidate] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if isDirectory.boolValue {
            return walk(url, folderPath: [url.lastPathComponent])
        }
        switch url.pathExtension.lowercased() {
        case "pdf":
            return [ImportCandidate(url: url, title: url.deletingPathExtension().lastPathComponent, folderPath: [], kind: .pdf)]
        case "goodnotes":
            return [ImportCandidate(url: url, title: url.deletingPathExtension().lastPathComponent, folderPath: [], kind: .goodNotesPackage)]
        case "zip":
            let destination = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try ZipArchive.extractAll(from: url, to: destination, extensions: ["pdf", "goodnotes"])
            // An archive of a GoodNotes folder usually contains that folder at its root.
            let roots = ((try? fm.contentsOfDirectory(at: destination, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            let folders = roots.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            if roots.count == 1, let only = folders.first {
                return walk(only, folderPath: [only.lastPathComponent])
            }
            return walk(destination, folderPath: [url.deletingPathExtension().lastPathComponent])
        default:
            return []
        }
    }

    private static func walk(_ directory: URL, folderPath: [String]) -> [ImportCandidate] {
        let fm = FileManager.default
        let items = ((try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var result: [ImportCandidate] = []
        for item in items {
            let name = item.lastPathComponent
            if name.hasPrefix(".") {
                // iCloud keeps files that aren't downloaded yet as ".Nom.pdf.icloud".
                if name.hasSuffix(".icloud") {
                    let original = String(name.dropFirst().dropLast(".icloud".count))
                    let ext = (original as NSString).pathExtension.lowercased()
                    if ext == "pdf" || ext == "goodnotes" {
                        try? fm.startDownloadingUbiquitousItem(at: item)
                        result.append(ImportCandidate(url: item, title: (original as NSString).deletingPathExtension,
                                                      folderPath: folderPath, kind: .notDownloaded))
                    }
                }
                continue
            }
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
               item.pathExtension.lowercased() != "goodnotes" {
                result += walk(item, folderPath: folderPath + [item.lastPathComponent])
                continue
            }
            let title = item.deletingPathExtension().lastPathComponent
            switch item.pathExtension.lowercased() {
            case "pdf": result.append(ImportCandidate(url: item, title: title, folderPath: folderPath, kind: .pdf))
            case "goodnotes": result.append(ImportCandidate(url: item, title: title, folderPath: folderPath, kind: .goodNotesPackage))
            default: break
            }
        }
        return result
    }

    /// GoodNotes writes its name in the PDF's creator or producer field.
    static func isGoodNotesPDF(_ url: URL) -> Bool {
        guard let attributes = PDFDocument(url: url)?.documentAttributes else { return false }
        let fields = [attributes[PDFDocumentAttribute.creatorAttribute], attributes[PDFDocumentAttribute.producerAttribute]]
        return fields.compactMap { $0 as? String }.contains { $0.localizedCaseInsensitiveContains("goodnotes") }
    }
}
