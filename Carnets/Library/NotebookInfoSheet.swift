import SwiftUI
import UniformTypeIdentifiers

// MARK: - NotebookInfoSheet (details, origin, and GoodNotes round-trips)

struct NotebookInfoSheet: View {
    let notebookID: UUID

    @Environment(NotebookStore.self) private var store
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var showUpdatePicker = false
    @State private var busy: String?
    @State private var message: String?
    @State private var sharedFile: SharedFile?
    @State private var pendingUpdate: URL?
    private let recognizer = ImportedTextRecognizer.shared

    private var notebook: Notebook? { store.notebook(notebookID) }

    var body: some View {
        NavigationStack {
            Form {
                if let notebook {
                    Section {
                        TextField("Titre", text: $title)
                            .font(.headline)
                            .onSubmit { store.rename(notebookID, to: title) }
                        Picker("Dossier", selection: Binding(get: { notebook.folderID }, set: { store.move(notebookID, to: $0) })) {
                            Text("Aucun dossier").tag(Optional<UUID>.none)
                            ForEach(store.folders) { folder in
                                Text(folder.name).tag(Optional(folder.id))
                            }
                        }
                        Toggle("Favori", isOn: Binding(get: { notebook.isFavorite }, set: { _ in store.toggleFavorite(notebookID) }))
                    }

                    Section("Informations") {
                        LabeledContent("Pages", value: "\(notebook.pages.count)")
                        LabeledContent("Créé", value: notebook.createdAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Modifié", value: notebook.modifiedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Origine", value: notebook.origin.label)
                        if let source = notebook.source {
                            if let name = source.originalName {
                                LabeledContent("Fichier d’origine", value: name)
                            }
                            LabeledContent("Importé", value: source.importedAt.formatted(date: .abbreviated, time: .shortened))
                            if let updated = source.updatedAt {
                                LabeledContent("Mis à jour", value: updated.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        let searchable = notebook.pages.filter { !$0.sourceText.isEmpty || !$0.recognizedText.isEmpty }.count
                        LabeledContent("Pages cherchables", value: "\(searchable) / \(notebook.pages.count)")
                    }

                    if notebook.source?.origin == .goodNotes || notebook.source?.origin == .pdf {
                        Section {
                            Button {
                                showUpdatePicker = true
                            } label: {
                                Label("Mettre à jour depuis un export plus récent…", systemImage: "arrow.triangle.2.circlepath")
                            }
                            if let file = notebook.source?.originalFile {
                                Button {
                                    shareOriginal(file, name: notebook.source?.originalName ?? notebook.title)
                                } label: {
                                    Label("Partager le PDF d’origine", systemImage: "doc")
                                }
                            }
                        } header: {
                            Text(notebook.origin == .goodNotes ? "GoodNotes" : "PDF")
                        } footer: {
                            Text("Continuez dans GoodNotes, exportez à nouveau en PDF, puis mettez à jour ici : chaque page est remplacée par sa nouvelle version, et ce que vous avez ajouté dans Carnets reste sur la bonne page.")
                        }
                    }

                    Section {
                        Button {
                            recognizer.enqueueAllPages(of: notebookID)
                            message = "La reconnaissance de l’écriture des pages importées a commencé."
                        } label: {
                            Label("Rendre les pages importées cherchables", systemImage: "text.viewfinder")
                        }
                        .disabled(!notebook.pages.contains { !$0.background.isTemplate })
                        Button {
                            HandwritingIndexer.shared.schedule(notebookID: notebookID, pageIDs: notebook.pages.map(\.id))
                            message = "L’écriture faite dans Carnets va être réindexée."
                        } label: {
                            Label("Réindexer l’écriture Carnets", systemImage: "pencil.and.scribble")
                        }
                        if recognizer.remaining > 0 {
                            HStack {
                                ProgressView()
                                Text("\(recognizer.remaining) page\(recognizer.remaining > 1 ? "s" : "") en cours de reconnaissance")
                                    .font(.callout)
                            }
                        }
                    } header: {
                        Text("Recherche")
                    }

                    Section {
                        Button {
                            exportForGoodNotes(notebook)
                        } label: {
                            Label("Envoyer vers GoodNotes (PDF)", systemImage: "square.and.arrow.up")
                        }
                        if let path = NotebookVaultBridge.shared.companionPath(for: notebookID) {
                            Button {
                                dismiss()
                                router.openNote(path, followNotebook: false)
                            } label: {
                                Label("Note liée dans le coffre", systemImage: "doc.text")
                            }
                        }
                    } header: {
                        Text("Partager")
                    } footer: {
                        Text("Le PDF contient les pages et toute l’écriture, y compris celle ajoutée dans Carnets. Dans la feuille de partage, choisissez GoodNotes pour l’y importer.")
                    }
                }
            }
            .navigationTitle(notebook?.title ?? "Carnet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") {
                        store.rename(notebookID, to: title)
                        dismiss()
                    }
                }
            }
            .overlay {
                if let busy {
                    VStack(spacing: 10) {
                        ProgressView()
                        Text(busy).font(.callout)
                    }
                    .padding(22)
                    .glassEffect(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                }
            }
            .fileImporter(isPresented: $showUpdatePicker, allowedContentTypes: [.pdf]) { result in
                guard case .success(let url) = result else { return }
                if store.sentToGoodNotesDate(notebookID) != nil {
                    pendingUpdate = url
                } else {
                    runUpdate(url, returningFromGoodNotes: false)
                }
            }
            .confirmationDialog("Ce PDF vient-il du carnet envoyé vers GoodNotes ?",
                                isPresented: Binding(get: { pendingUpdate != nil }, set: { if !$0 { pendingUpdate = nil } }),
                                titleVisibility: .visible) {
                Button("Oui : ne pas doubler l’encre Carnets") {
                    if let url = pendingUpdate { runUpdate(url, returningFromGoodNotes: true) }
                    pendingUpdate = nil
                }
                Button("Non : garder toute l’encre Carnets") {
                    if let url = pendingUpdate { runUpdate(url, returningFromGoodNotes: false) }
                    pendingUpdate = nil
                }
                Button("Annuler", role: .cancel) { pendingUpdate = nil }
            } message: {
                if let date = store.sentToGoodNotesDate(notebookID) {
                    Text("Vous avez envoyé ce carnet vers GoodNotes le \(date.formatted(date: .long, time: .shortened)). Son encre est alors imprimée dans le PDF : si cet export en provient, Carnets retire sa propre copie pour qu’elle n’apparaisse pas deux fois.")
                }
            }
            .alert("Carnet", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(message ?? "")
            }
            .sheet(item: $sharedFile) { file in
                ShareSheet(items: [file.url]).ignoresSafeArea()
            }
        }
        .onAppear { title = notebook?.title ?? "" }
    }

    private func runUpdate(_ url: URL, returningFromGoodNotes: Bool) {
        busy = "Mise à jour…"
        Task {
            do {
                let updated = try await store.updateNotebook(notebookID, fromPDF: url,
                                                             returningFromGoodNotes: returningFromGoodNotes)
                if updated?.origin == .goodNotes { recognizer.enqueueAllPages(of: notebookID) }
                message = "Carnet mis à jour : \(updated?.pages.count ?? 0) pages."
            } catch {
                message = error.localizedDescription
            }
            busy = nil
        }
    }

    /// Shares the imported PDF under its original name (GoodNotes names notebooks after the file).
    private func shareOriginal(_ file: String, name: String) {
        let source = store.files(for: notebookID).assetURL(file)
        let title = (name as NSString).deletingPathExtension
        let copy = PageRenderer.temporaryExportURL(title, ext: "pdf")
        do {
            try FileManager.default.copyItem(at: source, to: copy)
            sharedFile = SharedFile(url: copy)
        } catch {
            sharedFile = SharedFile(url: source)
        }
    }

    private func exportForGoodNotes(_ notebook: Notebook) {
        store.flush(notebook.id)
        store.waitForPendingWrites()
        guard let latest = store.notebook(notebook.id) else { return }
        let files = store.files(for: notebook.id)
        let url = PageRenderer.temporaryExportURL(latest.title, ext: "pdf")
        busy = "Préparation du PDF…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try PageRenderer.exportPDF(notebook: latest, files: files, drawings: nil, to: url)
                    // Remember what was printed, so the way back from GoodNotes doesn't double it.
                    FlattenedExport.record(latest, files: files).save(to: files)
                }.value
                sharedFile = SharedFile(url: url)
            } catch {
                message = error.localizedDescription
            }
            busy = nil
        }
    }
}
