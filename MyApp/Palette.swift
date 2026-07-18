import SwiftUI
import AppKit

// MARK: - PendingScroll
// Handoff from a palette heading selection to the editor, which may need to
// load the target sheet before it can scroll.

struct PendingScroll: Equatable {
    let sheetID: UUID
    let range: NSRange
}

// MARK: - PaletteState

@Observable final class PaletteState {
    static let shared = PaletteState()

    enum Mode { case navigate, commands }

    var isOpen = false
    var mode: Mode = .navigate
    var pendingScroll: PendingScroll?

    func open(_ mode: Mode) {
        if isOpen && self.mode == mode { isOpen = false; return }
        self.mode = mode
        isOpen = true
    }
}

// MARK: - PaletteCommands

struct PaletteCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button("Ouvrir rapidement…") { PaletteState.shared.open(.navigate) }
                .keyboardShortcut("o", modifiers: .command)
            Button("Palette de commandes…") { PaletteState.shared.open(.commands) }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

// MARK: - PaletteItem

struct PaletteItem: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let subtitle: String?
    let action: () -> Void
}

// MARK: - PaletteOverlay
// Builds the item lists from the library and the focused editor.

struct PaletteOverlay: View {
    @Environment(LibraryManager.self) private var library
    @FocusedValue(\.editorState) private var editorState
    @Binding var selectedGroupID: UUID?
    @Binding var selectedSheetID: UUID?
    @Binding var showProfile: Bool
    @Binding var showGroupExport: Bool

    var body: some View {
        PaletteView(
            items: PaletteState.shared.mode == .navigate ? navigationItems : commandItems,
            placeholder: PaletteState.shared.mode == .navigate
                ? "Feuilles, groupes, titres…"
                : "Commandes…",
            onDismiss: { PaletteState.shared.isOpen = false }
        )
    }

    // MARK: Navigation (⌘O)

    private var navigationItems: [PaletteItem] {
        var items: [PaletteItem] = []
        for group in library.allGroupsFlat() {
            items.append(PaletteItem(icon: group.iconName, title: group.title, subtitle: "Groupe") {
                showProfile = false
                selectedGroupID = group.id
            })
        }
        for (sheet, group) in library.sheetsWithGroups() {
            items.append(PaletteItem(icon: "doc.text", title: sheet.title, subtitle: group.title) {
                showProfile = false
                selectedGroupID = group.id
                selectedSheetID = sheet.id
            })
            for heading in MarkdownHighlighter.headings(in: sheet.plainText) {
                items.append(PaletteItem(icon: "number",
                                         title: heading.title,
                                         subtitle: "\(sheet.title) › Titre \(heading.level)") {
                    showProfile = false
                    selectedGroupID = group.id
                    selectedSheetID = sheet.id
                    PaletteState.shared.pendingScroll = PendingScroll(sheetID: sheet.id, range: heading.range)
                })
            }
        }
        return items
    }

    // MARK: Commands (⌘⇧P)

    private var commandItems: [PaletteItem] {
        var items: [PaletteItem] = []
        if let state = editorState {
            items += [
                PaletteItem(icon: "clock.badge.checkmark", title: "Enregistrer une version", subtitle: "⌘S") { state.requestSaveVersion?() },
                PaletteItem(icon: "clock.arrow.circlepath", title: "Historique des versions", subtitle: nil) { state.requestHistory?() },
                PaletteItem(icon: "square.and.arrow.up", title: "Exporter la feuille…", subtitle: "⌘E") { state.requestExport?() },
                PaletteItem(icon: "pencil.line", title: "Mode écriture", subtitle: "⌘⇧F") { state.toggleWritingMode() },
                PaletteItem(icon: "link.badge.plus", title: "Insérer un lien…", subtitle: "⌘K") { state.requestLink?() },
                PaletteItem(icon: "bold", title: "Gras", subtitle: "⌘B") { state.bold() },
                PaletteItem(icon: "italic", title: "Italique", subtitle: "⌘I") { state.italic() },
                PaletteItem(icon: "strikethrough", title: "Barré", subtitle: "⌘⇧X") { state.strikethrough() },
                PaletteItem(icon: "textformat.size.larger", title: "Titre 1", subtitle: "⌘⌥1") { state.heading(1) },
                PaletteItem(icon: "textformat.size", title: "Titre 2", subtitle: "⌘⌥2") { state.heading(2) },
                PaletteItem(icon: "textformat", title: "Corps de texte", subtitle: "⌘⌥0") { state.bodyStyle() },
            ]
        }
        if selectedGroupID != nil {
            items.append(PaletteItem(icon: "square.and.arrow.up.on.square", title: "Exporter le groupe…", subtitle: nil) {
                showGroupExport = true
            })
            items.append(PaletteItem(icon: "square.and.pencil", title: "Nouvelle feuille", subtitle: nil) {
                if let gid = selectedGroupID { selectedSheetID = library.addSheet(to: gid) }
            })
        }
        if let sid = selectedSheetID, let sheet = library.sheet(id: sid) {
            items.append(PaletteItem(icon: "paperclip",
                                     title: sheet.isMaterial ? "Ne plus marquer comme matériel" : "Marquer comme matériel",
                                     subtitle: sheet.title) {
                library.toggleMaterial(sid)
            })
        }
        items.append(PaletteItem(icon: "folder.badge.plus", title: "Nouveau groupe", subtitle: "⌘N") {
            library.createGroup()
        })
        return items
    }
}

// MARK: - PaletteView

struct PaletteView: View {
    let items: [PaletteItem]
    let placeholder: String
    var onDismiss: () -> Void

    @State private var query = ""
    @State private var selection = 0
    @State private var visible: [PaletteItem] = []
    @FocusState private var fieldFocused: Bool

    private static let maxVisible = 40

    // Filter once per query change, not once per body evaluation
    private func refilter() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else {
            visible = Array(items.prefix(Self.maxVisible))
            return
        }
        let lowered = q.lowercased()
        let ranked = items.enumerated().compactMap { index, item -> (item: PaletteItem, score: Int, index: Int)? in
            if item.title.localizedStandardContains(q) {
                return (item, item.title.lowercased().hasPrefix(lowered) ? 0 : 1, index)
            }
            if let sub = item.subtitle, sub.localizedStandardContains(q) {
                return (item, 2, index)
            }
            return nil
        }
        visible = Array(
            ranked
                .sorted { ($0.score, $0.index) < ($1.score, $1.index) }
                .map { $0.item }
                .prefix(Self.maxVisible)
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.08)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { onDismiss() }

            panel
                .padding(.top, 90)
        }
        .onExitCommand { onDismiss() }
    }

    private var panel: some View {
        GlassEffectContainer {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField(placeholder, text: $query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($fieldFocused)
                        .onSubmit { runSelected() }
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow)   { move(-1); return .handled }
                        .onExitCommand { onDismiss() }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)

                if !visible.isEmpty {
                    Divider()
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 1) {
                                ForEach(Array(visible.enumerated()), id: \.element.id) { index, item in
                                    row(item, highlighted: index == selection)
                                        .id(index)
                                        .onTapGesture { run(item) }
                                }
                            }
                            .padding(6)
                        }
                        .frame(maxHeight: 320)
                        .onChange(of: selection) { proxy.scrollTo(selection) }
                    }
                }
            }
            .frame(width: 560)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .onAppear {
            fieldFocused = true
            refilter()
        }
        .onChange(of: query) {
            selection = 0
            refilter()
        }
    }

    private func row(_ item: PaletteItem, highlighted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(highlighted ? Color.white : Color.secondary)
            Text(item.title)
                .lineLimit(1)
                .foregroundStyle(highlighted ? Color.white : Color.primary)
            Spacer()
            if let sub = item.subtitle {
                Text(sub)
                    .font(.caption)
                    .lineLimit(1)
                    .foregroundStyle(highlighted ? Color.white.opacity(0.8) : Color.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(highlighted ? Color.accentColor : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !visible.isEmpty else { return }
        selection = min(max(selection + delta, 0), visible.count - 1)
    }

    private func runSelected() {
        guard !visible.isEmpty else { return }
        run(visible[min(selection, visible.count - 1)])
    }

    private func run(_ item: PaletteItem) {
        onDismiss()
        item.action()
    }
}
