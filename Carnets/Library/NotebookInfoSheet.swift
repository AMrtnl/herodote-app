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
                                    sharedFile = SharedFile(url: store.files(for: notebookID).assetURL(file))
                                } label: {
                                    Label("Partager le PDF d’origine", systemImage: "doc")
                                }
                            }
                        } header: {
                            Text(notebook.origin == .goodNotes ? "GoodNotes" : "PDF")
                        } footer: {
                            Text("Continuez dans GoodNotes, exportez à nouveau en PDF, puis mettez à jour ici : les pages sont remplacées, et ce que vous avez ajouté dans Carnets reste sur les mêmes numéros de page.")
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
                busy = "Mise à jour…"
                Task {
                    do {
                        let updated = try await store.updateNotebook(notebookID, fromPDF: url)
                        if updated?.origin == .goodNotes { recognizer.enqueueAllPages(of: notebookID) }
                        message = "Carnet mis à jour : \(updated?.pages.count ?? 0) pages."
                    } catch {
                        message = error.localizedDescription
                    }
                    busy = nil
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

    private func exportForGoodNotes(_ notebook: Notebook) {
        store.flush(notebook.id)
        store.waitForPendingWrites()
        let files = store.files(for: notebook.id)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(PageRenderer.exportFileName(notebook.title, ext: "pdf"))
        busy = "Préparation du PDF…"
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try? FileManager.default.removeItem(at: url)
                    try PageRenderer.exportPDF(notebook: notebook, files: files, drawings: nil, to: url)
                }.value
                sharedFile = SharedFile(url: url)
            } catch {
                message = error.localizedDescription
            }
            busy = nil
        }
    }
}
