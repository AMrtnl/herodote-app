import SwiftUI
import UIKit

// MARK: - ProjectsView (Écriture: all writing projects + writing momentum)

struct ProjectsView: View {
    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router
    @State private var showNewProject = false
    @State private var projectName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ElanCard()
                if vault.projectFolders.isEmpty {
                    ContentUnavailableView {
                        Label("Aucun projet", systemImage: "text.book.closed")
                    } description: {
                        Text("Un projet regroupe des feuilles Markdown dans l’ordre, avec des objectifs de mots — comme dans Ulysses.")
                    } actions: {
                        Button("Nouveau projet") { showNewProject = true }
                            .buttonStyle(.glassProminent)
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260, maximum: 360), spacing: 18)], spacing: 18) {
                        ForEach(vault.projectFolders, id: \.self) { folder in
                            Button {
                                router.push(.project(folder))
                            } label: {
                                ProjectCard(folder: folder)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Écriture")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    projectName = ""
                    showNewProject = true
                } label: {
                    Label("Nouveau projet", systemImage: "plus")
                }
            }
        }
        .alert("Nouveau projet d’écriture", isPresented: $showNewProject) {
            TextField("Titre", text: $projectName)
            Button("Créer") {
                let folder = vault.createProject(title: projectName.isEmpty ? "Projet sans titre" : projectName)
                router.push(.project(folder))
            }
            Button("Annuler", role: .cancel) {}
        }
    }
}

struct ProjectCard: View {
    let folder: String
    @Environment(VaultStore.self) private var vault

    var body: some View {
        let project = vault.project(at: folder)
        let sheets = vault.sheets(of: folder)
        let words = sheets.reduce(0) { $0 + $1.wordCount }
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "doc.richtext").foregroundStyle(Color.accentColor)
                Text(project?.title ?? VaultPaths.fileName(of: folder))
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
            }
            Text(sheets.first?.excerpt.isEmpty == false ? sheets.first!.excerpt : "Feuilles vides")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3, reservesSpace: true)
            if let goal = project?.goal, goal > 0 {
                ProgressView(value: min(1, Double(words) / Double(goal)))
                    .tint(words >= goal ? .green : .accentColor)
            }
            HStack {
                Text("\(sheets.count) feuille\(sheets.count > 1 ? "s" : "") · \(words) mots")
                Spacer()
                if let deadline = project?.deadline {
                    Label(deadline.formatted(.relative(presentation: .named)), systemImage: "flag")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(18)
        .background(.background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 8, y: 3)
    }
}

// MARK: - Élan (writing momentum)

struct ElanCard: View {
    @Environment(WritingStats.self) private var stats

    var body: some View {
        let days = stats.lastDays(14)
        let peak = max(1, days.map { $0.words }.max() ?? 1)
        HStack(alignment: .bottom, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Élan").font(.title2.weight(.bold))
                HStack(spacing: 18) {
                    stat("\(stats.today)", "mots aujourd’hui", "pencil.line", .blue)
                    stat("\(stats.streak)", stats.streak > 1 ? "jours d’affilée" : "jour d’affilée", "flame.fill", .orange)
                }
            }
            Spacer()
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(day.words > 0 ? Color.accentColor : Color.secondary.opacity(0.2))
                        .frame(width: 9, height: max(4, 54 * CGFloat(day.words) / CGFloat(peak)))
                }
            }
            .accessibilityLabel("Mots écrits ces 14 derniers jours")
        }
        .padding(20)
        .background(.background, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private func stat(_ value: String, _ label: String, _ icon: String, _ tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title3.weight(.semibold)).monospacedDigit()
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - ProjectView (ordered sheets, goals, assemble & export)

struct ProjectView: View {
    let folder: String

    @Environment(VaultStore.self) private var vault
    @Environment(AppRouter.self) private var router
    @State private var editMode: EditMode = .inactive
    @State private var showGoals = false
    @State private var sharedFile: SharedFile?

    private var project: WritingProject? { vault.project(at: folder) }
    private var sheets: [VaultNote] { vault.sheets(of: folder) }

    var body: some View {
        let sheets = self.sheets
        let total = sheets.reduce(0) { $0 + $1.wordCount }
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(total)").font(.largeTitle.weight(.bold)).monospacedDigit()
                        Text("mots").foregroundStyle(.secondary)
                        Spacer()
                        if let goal = project?.goal, goal > 0 {
                            Text("objectif \(goal)").font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    if let goal = project?.goal, goal > 0 {
                        ProgressView(value: min(1, Double(total) / Double(goal)))
                            .tint(total >= goal ? .green : .accentColor)
                    }
                    if let deadline = project?.deadline {
                        Label("Échéance \(deadline.formatted(date: .long, time: .omitted)) (\(deadline.formatted(.relative(presentation: .named))))",
                              systemImage: "flag")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
            Section("Feuilles") {
                ForEach(sheets) { sheet in
                    Button {
                        router.push(.note(sheet.path))
                    } label: {
                        SheetRow(sheet: sheet, goal: project?.sheetGoals[VaultPaths.fileName(of: sheet.path)])
                    }
                    .buttonStyle(.plain)
                }
                .onMove { offsets, destination in
                    var names = sheets.map { VaultPaths.fileName(of: $0.path) }
                    names.move(fromOffsets: offsets, toOffset: destination)
                    vault.reorderSheets(in: folder, names: names)
                }
                .onDelete { offsets in
                    for index in offsets { vault.trash(sheets[index].path) }
                }
                Button {
                    let path = vault.addSheet(to: folder)
                    router.push(.note(path))
                } label: {
                    Label("Nouvelle feuille", systemImage: "plus")
                }
            }
        }
        .environment(\.editMode, $editMode)
        .navigationTitle(project?.title ?? VaultPaths.fileName(of: folder))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(editMode.isEditing ? "OK" : "Réorganiser") {
                    withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showGoals = true
                    } label: {
                        Label("Objectifs et échéance…", systemImage: "target")
                    }
                    Menu {
                        Button("PDF") { assemble(.pdf) }
                        Button("Markdown") { assemble(.markdown) }
                        Button("HTML") { assemble(.html) }
                    } label: {
                        Label("Assembler et exporter", systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label("Projet", systemImage: "ellipsis")
                }
            }
        }
        .sheet(isPresented: $showGoals) {
            ProjectGoalSheet(folder: folder)
        }
        .sheet(item: $sharedFile) { file in
            ShareSheet(items: [file.url]).ignoresSafeArea()
        }
    }

    /// Glues every sheet in order into one document, like Ulysses.
    private func assemble(_ format: MarkdownExporter.Format) {
        let parts = sheets.map { MarkdownSyntax.parseFrontmatter(vault.text(of: $0.path)).body.trimmingCharacters(in: .whitespacesAndNewlines) }
        let markdown = parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
        let title = project?.title ?? VaultPaths.fileName(of: folder)
        if let url = MarkdownExporter.export(title: title, markdown: markdown, format: format) {
            sharedFile = SharedFile(url: url)
        }
    }
}

struct SheetRow: View {
    let sheet: VaultNote
    let goal: Int?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(sheet.title).font(.body.weight(.semibold))
                if !sheet.excerpt.isEmpty {
                    Text(sheet.excerpt).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(sheet.wordCount)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                if let goal, goal > 0 {
                    Gauge(value: min(1, Double(sheet.wordCount) / Double(goal))) { EmptyView() }
                        .gaugeStyle(.accessoryCircularCapacity)
                        .tint(sheet.wordCount >= goal ? .green : .accentColor)
                        .scaleEffect(0.5)
                        .frame(width: 26, height: 26)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

struct ProjectGoalSheet: View {
    let folder: String
    @Environment(VaultStore.self) private var vault
    @Environment(\.dismiss) private var dismiss
    @State private var goal = 0
    @State private var hasDeadline = false
    @State private var deadline = Date.now.addingTimeInterval(30 * 86_400)
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Projet") {
                    TextField("Titre", text: $title)
                }
                Section("Objectif de mots") {
                    Stepper(value: $goal, in: 0...500_000, step: 500) {
                        Text(goal == 0 ? "Aucun objectif" : "\(goal) mots")
                    }
                }
                Section {
                    Toggle("Échéance", isOn: $hasDeadline)
                    if hasDeadline {
                        DatePicker("Date", selection: $deadline, displayedComponents: .date)
                    }
                }
            }
            .navigationTitle("Objectifs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Annuler") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Enregistrer") {
                        if var project = vault.project(at: folder) {
                            project.goal = goal == 0 ? nil : goal
                            project.deadline = hasDeadline ? deadline : nil
                            if !title.trimmingCharacters(in: .whitespaces).isEmpty { project.title = title }
                            vault.saveProject(project, at: folder)
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
        .onAppear {
            let project = vault.project(at: folder)
            goal = project?.goal ?? 0
            hasDeadline = project?.deadline != nil
            deadline = project?.deadline ?? deadline
            title = project?.title ?? ""
        }
    }
}
