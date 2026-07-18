import Foundation
import SwiftUI

@Observable final class LibraryManager {
    static let shared = LibraryManager()

    var groups: [WritingGroup] = []
    var activities: [String: Int] = [:]

    private let baseURL: URL
    private var saveTasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Computed

    /// Every sheet in the library at any nesting depth.
    var allSheets: [WritingSheet] { groups.flatMap { $0.allSheets } }

    // MARK: - Group CRUD

    func createGroup(title: String = "Nouveau Groupe") {
        let g = WritingGroup(title: title)
        groups.insert(g, at: 0)
        forceSave(g)
    }

    /// Backward-compat alias used by legacy call sites.
    func createProject(title: String = "Nouveau Groupe") { createGroup(title: title) }

    func delete(_ group: WritingGroup) {
        try? FileManager.default.removeItem(at: groupURL(group.id))
        groups.removeAll { $0.id == group.id }
    }

    /// Delete a group at any depth (root or nested).
    func deleteGroupFromTree(_ groupID: UUID) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            try? FileManager.default.removeItem(at: groupURL(groupID))
            groups.remove(at: idx)
            return
        }
        for idx in groups.indices {
            if groups[idx].deleteGroup(groupID) { scheduleSave(groups[idx]); return }
        }
    }

    /// Add a sub-group inside the group identified by `parentID`. Returns the new group's ID.
    @discardableResult
    func addSubGroup(title: String = "Nouveau Groupe", to parentID: UUID) -> UUID {
        let sub = WritingGroup(title: title)
        // Check if parentID is a top-level group first
        if let idx = groups.firstIndex(where: { $0.id == parentID }) {
            groups[idx].groups.append(sub)
            scheduleSave(groups[idx])
            return sub.id
        }
        for idx in groups.indices {
            if groups[idx].addSubGroup(sub, to: parentID) {
                scheduleSave(groups[idx]); break
            }
        }
        return sub.id
    }

    func renameGroup(_ groupID: UUID, to title: String) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].title = title
            scheduleSave(groups[idx])
        } else {
            for idx in groups.indices {
                if groups[idx].renameGroup(groupID, to: title) { scheduleSave(groups[idx]); return }
            }
        }
    }

    func updateGroupIcon(_ groupID: UUID, iconName: String, colorName: String) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].iconName = iconName
            groups[idx].iconColorName = colorName
            scheduleSave(groups[idx])
        } else {
            for idx in groups.indices {
                if groups[idx].updateIcon(groupID, iconName: iconName, colorName: colorName) {
                    scheduleSave(groups[idx]); return
                }
            }
        }
    }

    // MARK: - Sheet operations

    /// Find a sheet anywhere in the library.
    func sheet(id: UUID) -> WritingSheet? {
        groups.lazy.compactMap { $0.sheet(id: id) }.first
    }

    /// Find a group anywhere in the library.
    func group(id: UUID) -> WritingGroup? {
        func search(_ g: WritingGroup) -> WritingGroup? {
            if g.id == id { return g }
            return g.groups.lazy.compactMap { search($0) }.first
        }
        return groups.lazy.compactMap { search($0) }.first
    }

    /// Push an updated sheet back into the tree and schedule a debounced save.
    func updateSheet(_ sheet: WritingSheet) {
        for idx in groups.indices {
            if groups[idx].updateSheet(sheet.id, with: sheet) {
                scheduleSave(groups[idx]); return
            }
        }
    }

    /// Add a new sheet to the group identified by `groupID`. Returns the new sheet's ID.
    @discardableResult
    func addSheet(title: String = "Nouvelle feuille", to groupID: UUID) -> UUID {
        let sheet = WritingSheet(title: title)
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].sheets.append(sheet)
            scheduleSave(groups[idx])
        } else {
            for idx in groups.indices {
                if groups[idx].addSheet(sheet, to: groupID) { scheduleSave(groups[idx]); break }
            }
        }
        return sheet.id
    }

    func deleteSheet(_ sheetID: UUID) {
        for idx in groups.indices {
            if groups[idx].deleteSheet(sheetID) { scheduleSave(groups[idx]); return }
        }
    }

    func renameSheet(_ sheetID: UUID, to title: String) {
        for idx in groups.indices {
            if let si = groups[idx].sheets.firstIndex(where: { $0.id == sheetID }) {
                groups[idx].sheets[si].title = title
                scheduleSave(groups[idx]); return
            }
            // Check nested
            if groups[idx].renameSheet(sheetID, to: title) { scheduleSave(groups[idx]); return }
        }
    }

    /// Toggle a sheet's "material" flag (documentation sheets, excluded from stats and export).
    func toggleMaterial(_ sheetID: UUID) {
        guard var s = sheet(id: sheetID) else { return }
        s.isMaterial.toggle()
        updateSheet(s)
    }

    /// Every group at any nesting depth, depth-first.
    func allGroupsFlat() -> [WritingGroup] {
        var out: [WritingGroup] = []
        func walk(_ g: WritingGroup) { out.append(g); g.groups.forEach(walk) }
        groups.forEach(walk)
        return out
    }

    /// (sheet, owning group) pairs across the whole library.
    func sheetsWithGroups() -> [(sheet: WritingSheet, group: WritingGroup)] {
        allGroupsFlat().flatMap { g in g.sheets.map { (sheet: $0, group: g) } }
    }

    func moveSheets(in groupID: UUID, from offsets: IndexSet, to destination: Int) {
        if let idx = groups.firstIndex(where: { $0.id == groupID }) {
            groups[idx].sheets.move(fromOffsets: offsets, toOffset: destination)
            scheduleSave(groups[idx])
        } else {
            for idx in groups.indices {
                if groups[idx].moveSheets(in: groupID, from: offsets, to: destination) {
                    scheduleSave(groups[idx]); return
                }
            }
        }
    }

    // MARK: - Persistence

    func scheduleSave(_ group: WritingGroup) {
        saveTasks[group.id]?.cancel()
        let id = group.id
        saveTasks[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled, let self else { return }
            if let g = self.groups.first(where: { $0.id == id }) { self.forceSave(g) }
        }
    }

    // MARK: - Activity tracking

    func recordWords(_ count: Int) {
        guard count > 0 else { return }
        activities[todayKey(), default: 0] += count
        saveActivities()
    }

    var totalWordsAllTime: Int { activities.values.reduce(0, +) }
    var wordsToday: Int { activities[todayKey()] ?? 0 }

    var currentStreak: Int {
        let cal = Calendar.current
        var streak = 0
        var date = Date()
        while (activities[dateKey(date)] ?? 0) > 0 {
            streak += 1
            date = cal.date(byAdding: .day, value: -1, to: date)!
        }
        return streak
    }

    // MARK: - Private

    private init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        baseURL = appSupport.appendingPathComponent("Hérodote", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        loadAll()
    }

    private func loadAll() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let files = (try? FileManager.default
            .contentsOfDirectory(at: baseURL, includingPropertiesForKeys: [.contentModificationDateKey]))?
            .filter { $0.pathExtension == "herodote" } ?? []

        // WritingGroup's custom decoder handles old WritingProject files automatically.
        groups = files.compactMap { url -> WritingGroup? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder.decode(WritingGroup.self, from: data)
        }.sorted { $0.createdAt > $1.createdAt }

        if let data = try? Data(contentsOf: baseURL.appendingPathComponent("activity.json")),
           let dict = try? JSONDecoder().decode([String: Int].self, from: data) {
            activities = dict
        }

        if groups.isEmpty { createGroup() }
    }

    func forceSave(_ group: WritingGroup) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(group) else { return }
        try? data.write(to: groupURL(group.id), options: .atomic)
    }

    private func saveActivities() {
        guard let data = try? JSONEncoder().encode(activities) else { return }
        try? data.write(to: baseURL.appendingPathComponent("activity.json"), options: .atomic)
    }

    private func groupURL(_ id: UUID) -> URL {
        baseURL.appendingPathComponent("\(id.uuidString).herodote")
    }

    func todayKey() -> String { dateKey(Date()) }

    func dateKey(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
