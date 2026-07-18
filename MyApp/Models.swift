import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - WritingComment

struct WritingComment: Identifiable, Codable, Hashable {
    var id = UUID()
    var rangeLocation: Int
    var rangeLength: Int
    var text: String
    var author: String = ""
    var createdAt: Date = .now
    var resolved: Bool = false

    var nsRange: NSRange { NSRange(location: rangeLocation, length: rangeLength) }
}

// MARK: - SheetVersion
// A saved snapshot of a sheet's content, restorable from the history timeline.

struct SheetVersion: Identifiable, Codable, Hashable {
    var id = UUID()
    var createdAt: Date = .now
    var contentData: Data = Data()
    var wordCount: Int = 0

    enum CodingKeys: String, CodingKey { case id, createdAt, contentData, wordCount }

    init(contentData: Data, wordCount: Int) {
        self.contentData = contentData
        self.wordCount = wordCount
    }

    // Migration-safe: one malformed entry must not throw and wipe the whole
    // versions array (the array is decoded with try? at the WritingSheet level).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(UUID.self, forKey: .id))          ?? UUID()
        createdAt   = (try? c.decode(Date.self, forKey: .createdAt))   ?? .now
        contentData = (try? c.decode(Data.self, forKey: .contentData)) ?? Data()
        wordCount   = (try? c.decode(Int.self,  forKey: .wordCount))   ?? 0
    }

    var attributedString: NSAttributedString { decodeAttributedString(contentData) }
    var plainText: String { attributedString.string }
}

// MARK: - WritingSheet

struct WritingSheet: Identifiable, Codable {
    var id = UUID()
    var title: String
    var contentData: Data = Data()
    var comments: [WritingComment] = []
    var keywords: [String] = []
    var authorNotes: String = ""
    var wordGoal: Int? = nil
    var createdAt: Date = .now
    var modifiedAt: Date = .now
    var versions: [SheetVersion] = []
    var isMaterial: Bool = false

    enum CodingKeys: String, CodingKey {
        case id, title, contentData, comments, keywords, authorNotes,
             wordGoal, createdAt, modifiedAt, versions, isMaterial
    }

    init(title: String, seedText: String = "") {
        self.title = title
        if !seedText.isEmpty { self.contentData = makeContentData(seedText) }
    }

    // Migration-safe decoder: files written before versions/isMaterial existed must
    // keep decoding — WritingGroup's decoder silently drops sheet arrays that throw.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id          = (try? c.decode(UUID.self,             forKey: .id))          ?? UUID()
        title       = (try? c.decode(String.self,           forKey: .title))       ?? "Feuille"
        contentData = (try? c.decode(Data.self,             forKey: .contentData)) ?? Data()
        comments    = (try? c.decode([WritingComment].self, forKey: .comments))    ?? []
        keywords    = (try? c.decode([String].self,         forKey: .keywords))    ?? []
        authorNotes = (try? c.decode(String.self,           forKey: .authorNotes)) ?? ""
        wordGoal    = try? c.decodeIfPresent(Int.self,      forKey: .wordGoal)
        createdAt   = (try? c.decode(Date.self,             forKey: .createdAt))   ?? .now
        modifiedAt  = (try? c.decode(Date.self,             forKey: .modifiedAt))  ?? .now
        versions    = (try? c.decodeIfPresent([SheetVersion].self, forKey: .versions)) ?? []
        isMaterial  = (try? c.decodeIfPresent(Bool.self,    forKey: .isMaterial))  ?? false
    }

    var attributedString: NSAttributedString { decodeAttributedString(contentData) }

    var plainText: String { attributedString.string }
    var wordCount: Int { countWords(in: plainText) }
    var characterCount: Int { plainText.count }
    var paragraphCount: Int {
        plainText.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
    var readingTimeMinutes: Int { max(1, Int(ceil(Double(wordCount) / 200.0))) }
    var progressFraction: Double {
        guard let goal = wordGoal, goal > 0 else { return 0 }
        return min(1.0, Double(wordCount) / Double(goal))
    }

    var outgoingLinkIDs: [UUID] {
        let as_ = attributedString
        var ids: [UUID] = []
        as_.enumerateAttribute(.link, in: NSRange(location: 0, length: as_.length)) { val, _, _ in
            guard let url = val as? URL, url.scheme == "herodote",
                  let host = url.host, let id = UUID(uuidString: host) else { return }
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }
}

// MARK: - WritingGroup
// Recursive hierarchy: a group holds sub-groups and sheets.
// Custom decoder migrates old flat WritingProject files automatically.

struct WritingGroup: Identifiable, Codable {
    var id = UUID()
    var title: String
    var iconName: String = "folder.fill"
    var iconColorName: String = "bleu"
    var groups: [WritingGroup] = []
    var sheets: [WritingSheet] = []
    var createdAt: Date = .now

    enum CodingKeys: String, CodingKey {
        case id, title, iconName, iconColorName, groups, sheets, createdAt
    }

    // Default initialiser — seeds one blank Introduction sheet
    init(title: String = "Nouveau Groupe") {
        self.title = title
        sheets = [WritingSheet(
            title: "Introduction",
            seedText: "Commencez à écrire ici.\n\nSélectionnez du texte pour la barre de mise en forme. ⌘K insère un lien vers une autre feuille."
        )]
    }

    // Migration-safe decoder: old WritingProject files lack "groups"; any missing field gets a safe default.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id           = (try? c.decode(UUID.self,            forKey: .id))          ?? UUID()
        title        = (try? c.decode(String.self,          forKey: .title))        ?? "Groupe"
        iconName     = (try? c.decode(String.self,          forKey: .iconName))     ?? "folder.fill"
        iconColorName = (try? c.decode(String.self,         forKey: .iconColorName)) ?? "bleu"
        groups       = (try? c.decodeIfPresent([WritingGroup].self, forKey: .groups)) ?? []
        sheets       = (try? c.decode([WritingSheet].self,  forKey: .sheets))       ?? []
        createdAt    = (try? c.decode(Date.self,            forKey: .createdAt))    ?? .now
    }

    // MARK: Computed

    /// All sheets at any nesting depth, depth-first.
    var allSheets: [WritingSheet] {
        sheets + groups.flatMap { $0.allSheets }
    }

    // Material (documentation) sheets are excluded from stats, like Ulysses.
    var totalWordCount: Int { allSheets.filter { !$0.isMaterial }.reduce(0) { $0 + $1.wordCount } }

    func sheet(id: UUID) -> WritingSheet? { allSheets.first { $0.id == id } }
    func contains(sheetID: UUID) -> Bool  { allSheets.contains { $0.id == sheetID } }

    /// Non-nil only when sub-groups exist — used by List(children:) for hierarchical display.
    var subgroups: [WritingGroup]? { groups.isEmpty ? nil : groups }

    var displayColor: Color {
        switch iconColorName {
        case "violet":   return .purple
        case "rose":     return .pink
        case "rouge":    return .red
        case "orange":   return .orange
        case "jaune":    return .yellow
        case "vert":     return .green
        case "sarcelle": return .teal
        case "cyan":     return .cyan
        case "indigo":   return .indigo
        case "marron":   return .brown
        case "gris":     return .secondary
        default:         return .blue
        }
    }

    // MARK: Recursive mutations (return true when the target was found and mutated)

    mutating func updateSheet(_ sheetID: UUID, with sheet: WritingSheet) -> Bool {
        if let idx = sheets.firstIndex(where: { $0.id == sheetID }) {
            sheets[idx] = sheet; return true
        }
        for idx in groups.indices where groups[idx].updateSheet(sheetID, with: sheet) { return true }
        return false
    }

    mutating func addSheet(_ sheet: WritingSheet, to groupID: UUID) -> Bool {
        if id == groupID { sheets.append(sheet); return true }
        for idx in groups.indices where groups[idx].addSheet(sheet, to: groupID) { return true }
        return false
    }

    mutating func addSubGroup(_ sub: WritingGroup, to groupID: UUID) -> Bool {
        if id == groupID { groups.append(sub); return true }
        for idx in groups.indices where groups[idx].addSubGroup(sub, to: groupID) { return true }
        return false
    }

    mutating func deleteSheet(_ sheetID: UUID) -> Bool {
        if let idx = sheets.firstIndex(where: { $0.id == sheetID }) {
            sheets.remove(at: idx); return true
        }
        for idx in groups.indices where groups[idx].deleteSheet(sheetID) { return true }
        return false
    }

    mutating func deleteGroup(_ groupID: UUID) -> Bool {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups.remove(at: idx); return true
        }
        for idx in groups.indices where groups[idx].deleteGroup(groupID) { return true }
        return false
    }

    mutating func renameGroup(_ groupID: UUID, to newTitle: String) -> Bool {
        if id == groupID { title = newTitle; return true }
        for idx in groups.indices where groups[idx].renameGroup(groupID, to: newTitle) { return true }
        return false
    }

    mutating func updateIcon(_ groupID: UUID, iconName: String, colorName: String) -> Bool {
        if id == groupID { self.iconName = iconName; self.iconColorName = colorName; return true }
        for idx in groups.indices where groups[idx].updateIcon(groupID, iconName: iconName, colorName: colorName) { return true }
        return false
    }

    mutating func renameSheet(_ sheetID: UUID, to newTitle: String) -> Bool {
        if let idx = sheets.firstIndex(where: { $0.id == sheetID }) {
            sheets[idx].title = newTitle; return true
        }
        for idx in groups.indices where groups[idx].renameSheet(sheetID, to: newTitle) { return true }
        return false
    }

    mutating func moveSheets(in groupID: UUID, from offsets: IndexSet, to destination: Int) -> Bool {
        if id == groupID { sheets.move(fromOffsets: offsets, toOffset: destination); return true }
        for idx in groups.indices where groups[idx].moveSheets(in: groupID, from: offsets, to: destination) { return true }
        return false
    }
}

// MARK: - Word counting

/// Word count that ignores pure Markdown marker tokens ("#", "**", "~~", …).
func countWords(in text: String) -> Int {
    text.split { $0.isWhitespace || $0.isNewline }
        .filter { !$0.isEmpty && !$0.allSatisfy { "*#~".contains($0) } }
        .count
}

// MARK: - NSAttributedString helpers

func makeContentData(_ text: String) -> Data {
    encodeAttributedString(NSAttributedString(string: text,
                                              attributes: AppSettings.shared.defaultEditorAttributes))
}

/// Keyed-archive decode with the legacy RTF fallback — the single decode path
/// for sheet content and version snapshots.
func decodeAttributedString(_ data: Data) -> NSAttributedString {
    guard !data.isEmpty else { return NSAttributedString() }
    if let decoded = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) {
        return decoded
    }
    return (try? NSAttributedString(
        data: data,
        options: [.documentType: NSAttributedString.DocumentType.rtf],
        documentAttributes: nil
    )) ?? NSAttributedString()
}

func encodeAttributedString(_ as_: NSAttributedString) -> Data {
    (try? NSKeyedArchiver.archivedData(withRootObject: as_, requiringSecureCoding: false)) ?? Data()
}

// MARK: - Custom attribute for cross-sheet links

extension NSAttributedString.Key {
    static let herodoteLink = NSAttributedString.Key("HerodoteLinkTarget")
    /// Marks ranges styled by MarkdownHighlighter so its reset phase only ever
    /// undoes its own work (values are MarkdownHighlighter.Tag raw values).
    static let herodoteMD = NSAttributedString.Key("HerodoteMarkdown")
}
