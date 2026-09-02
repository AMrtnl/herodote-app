import SwiftUI

// MARK: - LibrarySourceList  (Column 1 — recursive group tree)

struct LibrarySourceList: View {
    @Environment(LibraryManager.self) private var library
    @Binding var selectedGroupID: UUID?
    @Binding var showProfile: Bool

    @State private var showNewGroup = false
    @State private var newGroupTitle = ""
    @State private var iconPickerGroup: WritingGroup?
    @State private var renamingGroupID: UUID?
    @State private var renamingTitle = ""

    var body: some View {
        List(library.groups, children: \.subgroups, selection: $selectedGroupID) { group in
            GroupSourceRow(
                group: group,
                renamingGroupID: $renamingGroupID,
                renamingTitle: $renamingTitle,
                onIconPick: { iconPickerGroup = group },
                onAddSubGroup: {
                    let id = library.addSubGroup(to: group.id)
                    selectedGroupID = id
                },
                onDelete: { library.deleteGroupFromTree(group.id) }
            )
        }
        .listStyle(.sidebar)
        .navigationTitle("Hérodote")
        .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 280)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom, spacing: 0) { elanFooter }
        .sheet(isPresented: $showNewGroup) { newGroupSheet }
        .sheet(item: $iconPickerGroup) { group in
            IconPickerSheet(group: group) { icon, color in
                library.updateGroupIcon(group.id, iconName: icon, colorName: color)
            }
        }
        .onSubmit(of: .text) {
            commitRename()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button { showNewGroup = true } label: { Image(systemName: "plus") }
                .help("Nouveau groupe (⌘N)")
        }
    }

    // MARK: Élan footer

    private var elanFooter: some View {
        Button { showProfile.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: showProfile ? "chart.bar.fill" : "chart.bar")
                    .foregroundStyle(showProfile ? Color.accentColor : Color.secondary)
                Text("Élan")
                    .foregroundStyle(showProfile ? Color.accentColor : Color.secondary)
                Spacer()
                if library.currentStreak > 0 {
                    Label("\(library.currentStreak)j", systemImage: "flame.fill")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .background(.bar)
    }

    // MARK: New group sheet

    private var newGroupSheet: some View {
        VStack(spacing: 20) {
            Text("Nouveau Groupe").font(.title3.bold())
            TextField("Nom du groupe", text: $newGroupTitle)
                .textFieldStyle(.roundedBorder).frame(width: 280)
                .onSubmit { commitNew() }
            HStack(spacing: 12) {
                Button("Annuler") { showNewGroup = false }.keyboardShortcut(.cancelAction)
                Button("Créer") { commitNew() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newGroupTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }

    private func commitNew() {
        let t = newGroupTitle.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        library.createGroup(title: t)
        selectedGroupID = library.groups.first?.id
        newGroupTitle = ""; showNewGroup = false
    }

    private func commitRename() {
        guard let id = renamingGroupID else { return }
        let t = renamingTitle.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { library.renameGroup(id, to: t) }
        renamingGroupID = nil
    }
}

// MARK: - GroupSourceRow

struct GroupSourceRow: View {
    @Environment(LibraryManager.self) private var library
    let group: WritingGroup
    @Binding var renamingGroupID: UUID?
    @Binding var renamingTitle: String
    var onIconPick: () -> Void
    var onAddSubGroup: () -> Void
    var onDelete: () -> Void

    var body: some View {
        if renamingGroupID == group.id {
            TextField("Nom", text: $renamingTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit { commitRename() }
                .onExitCommand { renamingGroupID = nil }
        } else {
            Label {
                VStack(alignment: .leading, spacing: 1) {
                    Text(group.title)
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(group.totalWordCount) mot\(group.totalWordCount != 1 ? "s" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            } icon: {
                iconTile
            }
            .contextMenu { contextMenu }
        }
    }

    private var iconTile: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(group.displayColor.opacity(0.15))
                .frame(width: 26, height: 26)
            Image(systemName: group.iconName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(group.displayColor)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Renommer") {
            renamingGroupID = group.id
            renamingTitle = group.title
        }
        Button("Nouveau sous-groupe") { onAddSubGroup() }
        Button("Changer l'icône…") { onIconPick() }
        Divider()
        Button("Supprimer", role: .destructive) { onDelete() }
    }

    private func commitRename() {
        let t = renamingTitle.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { library.renameGroup(group.id, to: t) }
        renamingGroupID = nil
    }
}

// MARK: - SheetListColumn  (Column 2 — sheets of the selected group)

struct SheetListColumn: View {
    @Environment(LibraryManager.self) private var library
    let groupID: UUID
    let group: WritingGroup
    @Binding var selectedSheetID: UUID?

    @State private var renamingSheetID: UUID?
    @State private var renamingTitle = ""

    var body: some View {
        List(selection: $selectedSheetID) {
            ForEach(group.sheets) { sheet in
                sheetRow(sheet).tag(sheet.id)
            }
            .onMove { from, to in library.moveSheets(in: groupID, from: from, to: to) }
            .onDelete { offsets in
                let ids = Set(offsets.map { group.sheets[$0].id })
                ids.forEach { library.deleteSheet($0) }
                if let sid = selectedSheetID, ids.contains(sid) {
                    selectedSheetID = group.sheets.first(where: { !ids.contains($0.id) })?.id
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(group.title)
        .navigationSplitViewColumnWidth(min: 190, ideal: 230, max: 300)
        .toolbar { sheetToolbar }
    }

    @ToolbarContentBuilder
    private var sheetToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                let id = library.addSheet(to: groupID)
                selectedSheetID = id
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .help("Nouvelle feuille")
        }
    }

    @ViewBuilder
    private func sheetRow(_ sheet: WritingSheet) -> some View {
        if renamingSheetID == sheet.id {
            TextField("Titre", text: $renamingTitle)
                .textFieldStyle(.plain)
                .font(.callout)
                .onSubmit { commitRename(sheet) }
                .onExitCommand { renamingSheetID = nil }
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(sheet.title)
                    .font(.callout)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(sheet.wordCount == 0 ? "Vide" : "\(sheet.wordCount) mot\(sheet.wordCount != 1 ? "s" : "")")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let goal = sheet.wordGoal, goal > 0 {
                        ProgressView(value: sheet.progressFraction)
                            .progressViewStyle(.linear)
                            .frame(width: 32)
                            .tint(sheet.progressFraction >= 1 ? .green : .accentColor)
                    }
                    if !sheet.keywords.isEmpty {
                        Image(systemName: "tag.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.quaternary)
                    }
                    if sheet.comments.contains(where: { !$0.resolved }) {
                        Image(systemName: "text.bubble.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(.orange.opacity(0.7))
                    }
                }
            }
            .padding(.vertical, 2)
            .contextMenu {
                Button("Renommer") { renamingSheetID = sheet.id; renamingTitle = sheet.title }
                Divider()
                Button("Supprimer", role: .destructive) {
                    library.deleteSheet(sheet.id)
                    if selectedSheetID == sheet.id { selectedSheetID = nil }
                }
            }
        }
    }

    private func commitRename(_ sheet: WritingSheet) {
        let t = renamingTitle.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { library.renameSheet(sheet.id, to: t) }
        renamingSheetID = nil
    }
}

// MARK: - IconPickerSheet

struct IconPickerSheet: View {
    let group: WritingGroup
    var onApply: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedIcon: String
    @State private var selectedColor: String

    init(group: WritingGroup, onApply: @escaping (String, String) -> Void) {
        self.group = group
        self.onApply = onApply
        _selectedIcon = State(initialValue: group.iconName)
        _selectedColor = State(initialValue: group.iconColorName)
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Icône du groupe")
                .font(.headline)
                .padding(16)
            Divider()
            IconPickerContent(iconName: $selectedIcon, colorName: $selectedColor)
            Divider()
            HStack(spacing: 12) {
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Appliquer") { onApply(selectedIcon, selectedColor); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
    }
}

// MARK: - IconPickerContent

struct IconPickerContent: View {
    @Binding var iconName: String
    @Binding var colorName: String

    private let icons = [
        "folder.fill", "doc.richtext.fill", "book.fill", "pencil.and.scribble",
        "newspaper.fill", "graduationcap.fill", "heart.fill",
        "star.fill", "bolt.fill", "leaf.fill", "moon.fill",
        "sun.max.fill", "flame.fill", "mountain.2.fill",
        "building.columns.fill", "camera.fill", "music.note",
        "film.fill", "map.fill", "globe", "magnifyingglass",
        "flag.fill", "bookmark.fill", "quote.bubble.fill", "lightbulb.fill"
    ]
    private let colorPairs: [(String, Color)] = [
        ("bleu", .blue), ("violet", .purple), ("rose", .pink),
        ("rouge", .red), ("orange", .orange), ("jaune", .yellow),
        ("vert", .green), ("sarcelle", .teal), ("cyan", .cyan),
        ("indigo", .indigo), ("marron", .brown), ("gris", .secondary)
    ]
    private var selectedColor: Color { colorPairs.first { $0.0 == colorName }?.1 ?? .blue }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 7) {
                ForEach(colorPairs, id: \.0) { name, color in
                    ZStack {
                        Circle().fill(color).frame(width: 20, height: 20)
                        if colorName == name {
                            Circle().stroke(Color.white, lineWidth: 2)
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: color.opacity(colorName == name ? 0.4 : 0), radius: 4)
                    .onTapGesture { colorName = name }
                }
            }
            let grid = Array(repeating: GridItem(.fixed(38), spacing: 6), count: 6)
            LazyVGrid(columns: grid, spacing: 6) {
                ForEach(icons, id: \.self) { icon in
                    let selected = iconName == icon
                    ZStack {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(selected ? selectedColor.opacity(0.15) : Color.secondary.opacity(0.07))
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .stroke(selectedColor, lineWidth: 1.5)
                                }
                            }
                        Image(systemName: icon)
                            .font(.system(size: 16))
                            .foregroundStyle(selected ? selectedColor : Color.secondary)
                    }
                    .frame(width: 38, height: 38)
                    .onTapGesture { iconName = icon }
                }
            }
        }
        .padding(16)
        .frame(width: 296)
    }
}
