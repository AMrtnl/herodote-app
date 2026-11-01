import SwiftUI
import UIKit
import Observation

// MARK: - NoteEditorController

@Observable final class NoteEditorController {
    private(set) var path: String
    private(set) var text: String
    var linkQuery: LinkQuery?
    private(set) var wordCount = 0
    private(set) var isDirty = false

    @ObservationIgnored weak var textView: MarkdownTextView?
    @ObservationIgnored var onOpenLink: ((String) -> Void)?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var savedWordCount = 0

    init(path: String) {
        self.path = path
        let initial = VaultStore.shared.text(of: path)
        self.text = initial
        self.wordCount = MarkdownSyntax.wordCount(initial)
        self.savedWordCount = wordCount
    }

    func textDidChange(_ newText: String) {
        text = newText
        isDirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        saveTask?.cancel()
        saveTask = nil
        guard isDirty else { return }
        VaultStore.shared.save(text, to: path)
        isDirty = false
        let words = MarkdownSyntax.wordCount(text)
        WritingStats.shared.record(words - savedWordCount)
        savedWordCount = words
        wordCount = words
    }

    func openLink(_ target: String) { onOpenLink?(target) }

    func rename(to title: String) {
        save()
        path = VaultStore.shared.renameNote(path, to: title)
    }

    /// Reloads from disk if the file changed elsewhere (sync, Obsidian) and we have no pending edits.
    func reloadIfChangedOnDisk() {
        guard !isDirty, let disk = VaultStore.shared.diskText(of: path), disk != text else { return }
        text = disk
        wordCount = MarkdownSyntax.wordCount(disk)
        savedWordCount = wordCount
        textView?.setMarkdown(disk)
    }

    func completeLink(with title: String) {
        guard let query = linkQuery else { return }
        textView?.completeLink(range: query.range, title: title)
        linkQuery = nil
    }

    /// Headings for the outline: (level, title, location).
    var outline: [(level: Int, title: String, location: Int)] {
        var result: [(level: Int, title: String, location: Int)] = []
        var location = 0
        var inCode = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("```") { inCode.toggle() }
            if !inCode, line.hasPrefix("#") {
                let level = line.prefix(while: { $0 == "#" }).count
                let title = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                if level <= 6, !title.isEmpty, line.dropFirst(level).first == " " {
                    result.append((level: level, title: title, location: location))
                }
            }
            location += (line as NSString).length + 1
        }
        return result
    }
}

// MARK: - NoteEditorView

struct NoteEditorView: View {
    let path: String
    /// Opens another note or a notebook (pushes onto the current navigation stack).
    var onNavigate: (String) -> Void

    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router
    @State private var controller: NoteEditorController
    @State private var showInspector = false
    @State private var writingMode = false
    @State private var title: String
    @State private var confirmDelete = false
    @State private var sharedFile: SharedFile?
    @AppStorage("notes.serif") private var serif = false
    @AppStorage("notes.fontSize") private var fontSize = 17.0
    @Environment(\.dismiss) private var dismiss

    init(path: String, onNavigate: @escaping (String) -> Void) {
        self.path = path
        self.onNavigate = onNavigate
        _controller = State(initialValue: NoteEditorController(path: path))
        _title = State(initialValue: VaultPaths.title(of: path))
    }

    private var theme: MarkdownTheme {
        MarkdownTheme(serif: serif || writingMode, fontSize: writingMode ? fontSize + 2 : fontSize,
                      lineSpacing: writingMode ? 7 : 4)
    }

    private var note: VaultNote? { vault.note(controller.path) }

    private var goal: Int? {
        let folder = VaultPaths.parent(of: controller.path)
        return vault.project(at: folder)?.sheetGoals[VaultPaths.fileName(of: controller.path)]
    }

    var body: some View {
        MarkdownEditor(controller: controller, theme: theme, writingMode: writingMode)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color(uiColor: .systemBackground))
            .overlay(alignment: .bottom) { suggestions }
            .overlay(alignment: .bottomLeading) { statusCapsule }
            .overlay(alignment: .topTrailing) { writingExitButton }
            .navigationTitle($title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarRole(.editor)
            .toolbar(writingMode ? .hidden : .visible, for: .navigationBar)
            .statusBarHidden(writingMode)
            .toolbar { toolbarContent }
            .inspector(isPresented: $showInspector) {
                NoteInspector(controller: controller, onNavigate: onNavigate)
                    .inspectorColumnWidth(min: 260, ideal: 300, max: 360)
            }
            .onChange(of: title) { _, newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != VaultPaths.title(of: controller.path) else { return }
                controller.rename(to: trimmed)
            }
            .onChange(of: vault.externalChangeToken) { controller.reloadIfChangedOnDisk() }
            .onAppear {
                controller.onOpenLink = { target in openLink(target) }
            }
            .onDisappear { controller.save() }
            .sheet(item: $sharedFile) { file in
                ShareSheet(items: [file.url]).ignoresSafeArea()
            }
            .confirmationDialog("Mettre « \(title) » à la corbeille ?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Mettre à la corbeille", role: .destructive) {
                    controller.save()
                    vault.trash(controller.path)
                    dismiss()
                }
            } message: {
                Text("La note est déplacée dans le dossier .trash du coffre, comme dans Obsidian.")
            }
            .animation(.snappy, value: writingMode)
            .animation(.snappy, value: controller.linkQuery)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                writingMode = true
                controller.textView?.becomeFirstResponder()
            } label: {
                Label("Mode écriture", systemImage: "text.cursor")
            }
            Button {
                showInspector.toggle()
            } label: {
                Label("Inspecteur", systemImage: "sidebar.right")
            }
            Menu {
                Toggle(isOn: $serif) { Label("Police à empattements", systemImage: "textformat") }
                Picker("Taille du texte", selection: $fontSize) {
                    Text("Petite").tag(15.0)
                    Text("Normale").tag(17.0)
                    Text("Grande").tag(20.0)
                }
                Divider()
                Button {
                    UIPasteboard.general.string = "[[\(VaultPaths.title(of: controller.path))]]"
                } label: {
                    Label("Copier le lien interne", systemImage: "link")
                }
                Menu {
                    Button("PDF") { export(.pdf) }
                    Button("Markdown") { export(.markdown) }
                    Button("HTML") { export(.html) }
                } label: {
                    Label("Exporter", systemImage: "square.and.arrow.up")
                }
                Divider()
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Mettre à la corbeille", systemImage: "trash")
                }
            } label: {
                Label("Plus", systemImage: "ellipsis")
            }
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var suggestions: some View {
        if let query = controller.linkQuery {
            let matches = vault.linkSuggestions(for: query.text)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(matches) { note in
                    Button {
                        controller.completeLink(with: note.title)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: note.kind)).foregroundStyle(.secondary).frame(width: 20)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(note.title).font(.callout.weight(.medium))
                                if !note.folder.isEmpty {
                                    Text(note.folder).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if !query.text.isEmpty && !matches.contains(where: { $0.title.lowercased() == query.text.lowercased() }) {
                    Button {
                        controller.completeLink(with: VaultPaths.sanitizedName(query.text))
                    } label: {
                        Label("Lier à une nouvelle note « \(query.text) »", systemImage: "plus")
                            .font(.callout)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: 420)
            .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .padding(.bottom, 12)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var statusCapsule: some View {
        HStack(spacing: 8) {
            Text("\(controller.wordCount) mot\(controller.wordCount > 1 ? "s" : "")")
            if let goal, goal > 0 {
                ProgressView(value: min(1, Double(controller.wordCount) / Double(goal)))
                    .progressViewStyle(.circular)
                    .controlSize(.mini)
                    .tint(controller.wordCount >= goal ? .green : .accentColor)
                Text("/ \(goal)")
            }
        }
        .font(.caption.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(in: Capsule())
        .padding(16)
        .opacity(controller.linkQuery == nil ? (writingMode ? 0.6 : 1) : 0)
    }

    @ViewBuilder
    private var writingExitButton: some View {
        if writingMode {
            Button {
                writingMode = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .opacity(0.5)
            .padding(16)
            .accessibilityLabel("Quitter le mode écriture")
        }
    }

    private func icon(for kind: NoteKind) -> String {
        switch kind {
        case .note:     return "doc.text"
        case .daily:    return "calendar"
        case .notebook: return "pencil.and.scribble"
        case .sheet:    return "text.page"
        }
    }

    // MARK: Actions

    private func openLink(_ target: String) {
        controller.save()
        if let resolved = vault.resolve(target, from: controller.path) {
            if let notebookID = vault.note(resolved)?.notebookID {
                router.openNotebook(notebookID)
            } else {
                onNavigate(resolved)
            }
        } else {
            // Like Obsidian: following a link to a missing note creates it.
            let folder = VaultPaths.parent(of: controller.path)
            let created = vault.createNote(in: folder, title: target, body: "# \(VaultPaths.sanitizedName(target))\n\n")
            onNavigate(created)
        }
    }

    private func export(_ format: MarkdownExporter.Format) {
        controller.save()
        let name = VaultPaths.title(of: controller.path)
        if let url = MarkdownExporter.export(title: name, markdown: controller.text, format: format) {
            sharedFile = SharedFile(url: url)
        }
    }
}

// MARK: - Inspector (backlinks, outline, tags, properties, stats)

struct NoteInspector: View {
    let controller: NoteEditorController
    var onNavigate: (String) -> Void

    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router

    private var note: VaultNote? { vault.note(controller.path) }

    var body: some View {
        List {
            Section("Statistiques") {
                LabeledContent("Mots", value: "\(controller.wordCount)")
                LabeledContent("Caractères", value: "\(controller.text.count)")
                LabeledContent("Lecture", value: "\(max(1, controller.wordCount / 230)) min")
                if let note {
                    LabeledContent("Modifiée", value: note.modified.formatted(date: .abbreviated, time: .shortened))
                }
                goalRow
            }
            let backlinks = vault.backlinks[controller.path] ?? []
            Section("Rétroliens (\(backlinks.count))") {
                if backlinks.isEmpty {
                    Text("Aucune note ne renvoie ici.").font(.footnote).foregroundStyle(.secondary)
                }
                ForEach(backlinks, id: \.self) { source in
                    Button {
                        onNavigate(source)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Label(VaultPaths.title(of: source), systemImage: "arrow.uturn.left")
                                .font(.callout.weight(.medium))
                            if let excerpt = vault.note(source)?.excerpt, !excerpt.isEmpty {
                                Text(excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            let outgoing = vault.outgoing[controller.path] ?? []
            let unresolved = (note?.links ?? []).filter { vault.resolve($0, from: controller.path) == nil }
            Section("Liens sortants (\(outgoing.count + unresolved.count))") {
                ForEach(outgoing, id: \.self) { target in
                    Button {
                        if let id = vault.note(target)?.notebookID { router.openNotebook(id) } else { onNavigate(target) }
                    } label: {
                        Label(VaultPaths.title(of: target),
                              systemImage: vault.note(target)?.kind == .notebook ? "pencil.and.scribble" : "arrow.right")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(unresolved, id: \.self) { name in
                    Button {
                        let created = vault.createNote(in: VaultPaths.parent(of: controller.path), title: name, body: "# \(name)\n\n")
                        onNavigate(created)
                    } label: {
                        Label("\(name) — créer", systemImage: "plus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            let outline = controller.outline
            if !outline.isEmpty {
                Section("Plan") {
                    ForEach(Array(outline.enumerated()), id: \.offset) { _, item in
                        Button {
                            controller.textView?.scrollTo(location: item.location)
                        } label: {
                            Text(item.title)
                                .font(item.level <= 1 ? .callout.weight(.semibold) : .callout)
                                .padding(.leading, CGFloat(item.level - 1) * 12)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let note, !note.tags.isEmpty {
                Section("Étiquettes") {
                    FlowTags(tags: note.tags)
                }
            }
            if let note, !note.properties.isEmpty {
                Section("Propriétés") {
                    ForEach(note.properties.keys.sorted(), id: \.self) { key in
                        LabeledContent(key, value: note.properties[key] ?? "")
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private var goalRow: some View {
        let folder = VaultPaths.parent(of: controller.path)
        if let project = vault.project(at: folder) {
            let name = VaultPaths.fileName(of: controller.path)
            Picker("Objectif", selection: Binding(
                get: { project.sheetGoals[name] ?? 0 },
                set: { value in
                    var updated = project
                    updated.sheetGoals[name] = value == 0 ? nil : value
                    vault.saveProject(updated, at: folder)
                })) {
                Text("Aucun").tag(0)
                ForEach([250, 500, 1000, 1500, 2000, 3000, 5000], id: \.self) { Text("\($0) mots").tag($0) }
            }
        }
    }
}

struct FlowTags: View {
    let tags: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                }
            }
        }
    }
}

// MARK: - Writing statistics ("Élan", shared with Hérodote's naming)

@Observable final class WritingStats {
    static let shared = WritingStats()

    private(set) var days: [String: Int]

    private init() {
        days = (UserDefaults.standard.dictionary(forKey: "writing.days") as? [String: Int]) ?? [:]
    }

    func record(_ delta: Int) {
        guard delta > 0 else { return }
        days[VaultStore.dailyName(for: .now), default: 0] += delta
        UserDefaults.standard.set(days, forKey: "writing.days")
    }

    var today: Int { days[VaultStore.dailyName(for: .now)] ?? 0 }

    var streak: Int {
        var count = 0
        var date = Date.now
        while (days[VaultStore.dailyName(for: date)] ?? 0) > 0 {
            count += 1
            guard let previous = Calendar.current.date(byAdding: .day, value: -1, to: date) else { break }
            date = previous
        }
        return count
    }

    /// Words per day for the last `count` days, oldest first.
    func lastDays(_ count: Int) -> [(date: Date, words: Int)] {
        (0..<count).reversed().compactMap { offset in
            guard let date = Calendar.current.date(byAdding: .day, value: -offset, to: .now) else { return nil }
            return (date: date, words: days[VaultStore.dailyName(for: date)] ?? 0)
        }
    }
}
