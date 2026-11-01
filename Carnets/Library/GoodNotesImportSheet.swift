import SwiftUI
import UniformTypeIdentifiers
import Observation

// MARK: - Import session (runs the import and keeps a log)

@Observable final class GoodNotesImportSession {
    nonisolated enum Status: Sendable { case working, imported, updated, skipped, failed }

    struct Entry: Identifiable {
        let id = UUID()
        var title: String
        var detail: String
        var status: Status
        var notebookID: UUID?
    }

    var entries: [Entry] = []
    private(set) var isRunning = false
    var keepFolders = true
    var updateExisting = true
    var recognizeHandwriting = true
    /// Exports of notebooks sent from Carnets: drop the Carnets ink already printed on the pages.
    var returningFromGoodNotes = true
    /// Notebooks created or updated during this session (never updated twice).
    @ObservationIgnored private var touched: Set<UUID> = []

    var importedCount: Int { entries.filter { $0.status == .imported || $0.status == .updated }.count }

    func run(urls: [URL]) async {
        guard !isRunning else { return }
        isRunning = true
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("import-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        for url in urls {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let candidates = try await Task.detached(priority: .userInitiated) {
                    try GoodNotesImporter.candidates(from: url, workDirectory: work)
                }.value
                if candidates.isEmpty {
                    entries.append(Entry(title: url.lastPathComponent,
                                         detail: "Aucun PDF trouvé dans ce fichier ou ce dossier.", status: .skipped))
                }
                for candidate in candidates {
                    await importCandidate(candidate)
                }
            } catch {
                entries.append(Entry(title: url.lastPathComponent, detail: error.localizedDescription, status: .failed))
            }
        }
        try? FileManager.default.removeItem(at: work)
        isRunning = false
    }

    private func importCandidate(_ candidate: ImportCandidate) async {
        let store = NotebookStore.shared
        let index = entries.count
        entries.append(Entry(title: candidate.title, detail: "Importation…", status: .working))
        switch candidate.kind {
        case .notDownloaded:
            entries[index].status = .skipped
            entries[index].detail = "Pas encore téléchargé depuis iCloud : le téléchargement a été demandé, réessayez dans un instant."
        case .goodNotesPackage:
            entries[index].status = .skipped
            entries[index].detail = "Fichier .goodnotes : son format est propre à GoodNotes. Dans GoodNotes, choisissez Partager › Exporter › PDF pour importer les pages et l’écriture."
        case .pdf:
            do {
                let url = candidate.url
                let isGoodNotes = await Task.detached(priority: .userInitiated) {
                    GoodNotesImporter.isGoodNotesPDF(url)
                }.value
                let notebook: Notebook?
                if updateExisting,
                   let existing = store.importedNotebook(matching: url.lastPathComponent,
                                                         origin: isGoodNotes ? .goodNotes : .pdf,
                                                         folderPath: keepFolders ? candidate.folderPath : nil,
                                                         excluding: touched) {
                    let roundTrip = returningFromGoodNotes && store.sentToGoodNotesDate(existing.id) != nil
                    notebook = try await store.updateNotebook(existing.id, fromPDF: url, returningFromGoodNotes: roundTrip)
                    entries[index].status = .updated
                    entries[index].detail = "\(notebook?.pages.count ?? 0) pages · mis à jour, "
                        + (roundTrip ? "l’encre déjà envoyée vers GoodNotes n’est pas doublée" : "l’encre ajoutée dans Carnets est conservée")
                } else {
                    let folderID = keepFolders ? store.folderID(forPath: candidate.folderPath) : nil
                    notebook = try await store.importPDF(from: url, title: candidate.title, folderID: folderID)
                    entries[index].status = .imported
                    let origin = notebook?.origin == .goodNotes ? "GoodNotes" : "PDF"
                    entries[index].detail = "\(notebook?.pages.count ?? 0) pages · \(origin)"
                        + (candidate.folderPath.isEmpty || !keepFolders ? "" : " · dossier « \(candidate.folderPath.joined(separator: " › ")) »")
                }
                entries[index].notebookID = notebook?.id
                if let id = notebook?.id { touched.insert(id) }
                if recognizeHandwriting, let id = notebook?.id {
                    ImportedTextRecognizer.shared.enqueueAllPages(of: id)
                }
            } catch {
                entries[index].status = .failed
                entries[index].detail = error.localizedDescription
            }
        }
    }
}

// MARK: - Sheet

struct GoodNotesImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppRouter.self) private var router
    @State private var session = GoodNotesImportSession()
    @State private var showPicker = false
    private let recognizer = ImportedTextRecognizer.shared

    private var contentTypes: [UTType] {
        var types: [UTType] = [.pdf, .zip, .folder]
        if let goodNotes = UTType(filenameExtension: "goodnotes") { types.append(goodNotes) }
        return types
    }

    var body: some View {
        @Bindable var session = session
        NavigationStack {
            Form {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Exporter depuis GoodNotes").font(.headline)
                            Text("Dans GoodNotes, sélectionnez des carnets ou un dossier, puis Partager › Exporter › **PDF**. Un dossier est exporté en archive ZIP. Enregistrez dans Fichiers, puis choisissez les fichiers ici.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "square.and.arrow.down.on.square").foregroundStyle(Color.accentColor)
                    }
                    Label {
                        Text("Vos carnets restent intacts dans GoodNotes : vous pouvez continuer à utiliser les deux applications, et réimporter un export plus récent à tout moment.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(Color.accentColor)
                    }
                }

                Section("Options") {
                    Toggle("Recréer les dossiers de GoodNotes", isOn: $session.keepFolders)
                    Toggle("Mettre à jour les carnets déjà importés", isOn: $session.updateExisting)
                    Toggle("Rendre l’écriture cherchable", isOn: $session.recognizeHandwriting)
                    Toggle("Ne pas doubler l’encre envoyée vers GoodNotes", isOn: $session.returningFromGoodNotes)
                }

                Section {
                    Button {
                        showPicker = true
                    } label: {
                        Label("Choisir des PDF, ZIP ou dossiers…", systemImage: "folder")
                    }
                    .disabled(session.isRunning)
                } footer: {
                    Text("Mise à jour : l’encre, le texte, les images et les marque-pages ajoutés dans Carnets restent sur les mêmes numéros de page. La reconnaissance d’écriture s’effectue sur l’appareil.")
                }

                if !session.entries.isEmpty {
                    Section(session.isRunning ? "Importation…" : "\(session.importedCount) carnet\(session.importedCount > 1 ? "s" : "") importé\(session.importedCount > 1 ? "s" : "")") {
                        ForEach(session.entries) { entry in
                            Button {
                                if let id = entry.notebookID {
                                    dismiss()
                                    router.openNotebook(id)
                                }
                            } label: {
                                HStack(alignment: .top, spacing: 12) {
                                    statusIcon(entry.status).frame(width: 22)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title).font(.body.weight(.medium))
                                        Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(entry.notebookID == nil)
                        }
                    }
                }

                if recognizer.remaining > 0 {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Reconnaissance de l’écriture : \(recognizer.remaining) page\(recognizer.remaining > 1 ? "s" : "") restante\(recognizer.remaining > 1 ? "s" : "")")
                                .font(.callout)
                        }
                    } footer: {
                        Text("Vous pouvez fermer cette fenêtre : la reconnaissance continue en arrière-plan.")
                    }
                }
            }
            .navigationTitle("Importer depuis GoodNotes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                        .disabled(session.isRunning)
                }
            }
            .fileImporter(isPresented: $showPicker, allowedContentTypes: contentTypes, allowsMultipleSelection: true) { result in
                if case .success(let urls) = result {
                    Task { await session.run(urls: urls) }
                }
            }
        }
    }

    @ViewBuilder
    private func statusIcon(_ status: GoodNotesImportSession.Status) -> some View {
        switch status {
        case .working:  ProgressView().controlSize(.small)
        case .imported: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .updated:  Image(systemName: "arrow.triangle.2.circlepath.circle.fill").foregroundStyle(Color.accentColor)
        case .skipped:  Image(systemName: "info.circle.fill").foregroundStyle(.orange)
        case .failed:   Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
        }
    }
}
