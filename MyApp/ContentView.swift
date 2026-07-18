import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let herodote = UTType(exportedAs: "com.herodote.project")
}

// MARK: - App

@main
struct HerodoApp: App {
    var body: some Scene {
        WindowGroup {
            LibraryRootView()
                .environment(LibraryManager.shared)
        }
        .defaultSize(width: 1280, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Nouveau Groupe") { LibraryManager.shared.createGroup() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            FormatCommands()
            PaletteCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

// MARK: - Library Root  (3-column: source tree | sheet list | editor)

struct LibraryRootView: View {
    @Environment(LibraryManager.self) private var library
    @State private var selectedGroupID: UUID?
    @State private var selectedSheetID: UUID?
    @State private var showProfile = false
    @State private var showGroupExport = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            // Column 1 — Hierarchical group tree
            LibrarySourceList(
                selectedGroupID: $selectedGroupID,
                showProfile: $showProfile
            )
        } content: {
            // Column 2 — Sheets in the selected group
            if let groupID = selectedGroupID,
               let group = library.group(id: groupID) {
                SheetListColumn(groupID: groupID, group: group, selectedSheetID: $selectedSheetID)
            } else {
                ContentUnavailableView("Sélectionnez un groupe",
                                       systemImage: "folder",
                                       description: Text("Choisissez un groupe dans la barre latérale."))
            }
        } detail: {
            // Column 3 — Editor / Élan / Welcome
            if showProfile {
                ProfileView()
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showProfile = false } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                            }
                            .help("Fermer Élan")
                        }
                    }
            } else if let sheetID = selectedSheetID {
                EditorDetailView(
                    sheet: sheetBinding(for: sheetID),
                    allSheets: library.allSheets,
                    onNavigate: { id in selectedSheetID = id }
                )
                .id(sheetID)
            } else {
                WelcomeDetail(showProfile: $showProfile)
            }
        }
        .overlay {
            if PaletteState.shared.isOpen {
                PaletteOverlay(
                    selectedGroupID: $selectedGroupID,
                    selectedSheetID: $selectedSheetID,
                    showProfile: $showProfile,
                    showGroupExport: $showGroupExport
                )
            }
        }
        .sheet(isPresented: $showGroupExport) {
            if let groupID = selectedGroupID, let group = library.group(id: groupID) {
                ExportSheet(sheets: group.allSheets, title: group.title) { showGroupExport = false }
            }
        }
        .onChange(of: AppSettings.shared.writingMode) { _, writing in
            withAnimation(.easeInOut(duration: 0.25)) {
                columnVisibility = writing ? .detailOnly : .all
            }
        }
        .onChange(of: selectedGroupID) { _, groupID in
            guard let id = groupID, let group = library.group(id: id) else { return }
            // Auto-select first sheet when switching groups (unless current sheet is in this group)
            if let sid = selectedSheetID, group.contains(sheetID: sid) { return }
            selectedSheetID = group.sheets.first?.id
        }
        .task {
            if selectedGroupID == nil {
                selectedGroupID = library.groups.first?.id
                selectedSheetID = library.groups.first?.sheets.first?.id
            }
        }
    }

    private func sheetBinding(for sheetID: UUID) -> Binding<WritingSheet> {
        Binding(
            get: { library.sheet(id: sheetID) ?? WritingSheet(title: "") },
            set: { library.updateSheet($0) }
        )
    }
}

// MARK: - Welcome Detail

struct WelcomeDetail: View {
    @Environment(LibraryManager.self) private var library
    @Binding var showProfile: Bool

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 16) {
                Image(systemName: "doc.richtext")
                    .font(.system(size: 48, weight: .ultraLight))
                    .foregroundStyle(.tertiary)
                Text("Hérodote")
                    .font(.system(size: 28, weight: .semibold, design: .serif))
                Text("L'écriture invisible")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
            Spacer()
            Divider()
            HStack(spacing: 24) {
                Button { library.createGroup() } label: {
                    Label("Nouveau groupe", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                Button { showProfile = true } label: {
                    Label("Élan", systemImage: "chart.bar")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .font(.callout)
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
