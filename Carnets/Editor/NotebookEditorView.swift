import SwiftUI
import UIKit
import PhotosUI
import UniformTypeIdentifiers
import VisionKit
import PencilKit

// MARK: - NotebookEditorView

struct NotebookEditorView: View {
    let notebookID: UUID
    var onClose: () -> Void

    @State private var model: EditorModel
    @State private var photoItem: PhotosPickerItem?
    @State private var showPhotoPicker = false
    @State private var showPDFImporter = false
    @State private var showScanner = false
    @State private var showRename = false
    @State private var renameText = ""
    @State private var confirmClear = false

    init(notebookID: UUID, onClose: @escaping () -> Void) {
        self.notebookID = notebookID
        self.onClose = onClose
        _model = State(initialValue: EditorModel(notebookID: notebookID))
    }

    private var paletteInset: CGFloat { model.focusMode ? 0 : 66 }

    var body: some View {
        NavigationStack {
            ZStack(alignment: .top) {
                NotebookCanvas(model: model, configuration: model.configuration,
                               topInset: paletteInset, bottomInset: 0)
                    .ignoresSafeArea(edges: .bottom)

                if !model.isLoaded {
                    ProgressView()
                        .controlSize(.large)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if !model.focusMode {
                    VStack(spacing: 10) {
                        ToolPaletteView(model: model)
                        contextualBar
                    }
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .overlay(alignment: .bottomTrailing) { pageIndicator }
            .overlay(alignment: .bottom) { toastView }
            .overlay(alignment: .topTrailing) { focusExitButton }
            .overlay { busyOverlay }
            .animation(.snappy(duration: 0.25), value: model.focusMode)
            .animation(.snappy(duration: 0.2), value: model.isSearching)
            .animation(.snappy(duration: 0.2), value: model.selectedElementID)
            .animation(.snappy(duration: 0.2), value: model.hasStrokeSelection)
            .animation(.snappy, value: model.toast)
            .navigationTitle(model.notebook?.title ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarTitleMenu {
                Button {
                    renameText = model.notebook?.title ?? ""
                    showRename = true
                } label: {
                    Label("Renommer", systemImage: "pencil")
                }
                Button {
                    model.exportPDF()
                } label: {
                    Label("Exporter en PDF", systemImage: "square.and.arrow.up")
                }
            }
            .toolbar(model.focusMode ? .hidden : .visible, for: .navigationBar)
            .toolbar { toolbarContent }
            .statusBarHidden(model.focusMode)
            .persistentSystemOverlays(model.focusMode ? .hidden : .automatic)
        }
        .sheet(isPresented: $model.showPageNavigator) {
            PageNavigatorView(model: model)
        }
        .sheet(item: $model.templatePicker) { request in
            TemplatePickerSheet(model: model, mode: request.mode)
        }
        .sheet(item: $model.textEdit) { request in
            TextElementEditor(request: request) { text, size, style, color in
                model.canvas?.commitText(request, text: text, fontSize: size, style: style, colorHex: color)
            }
        }
        .sheet(item: $model.conversion) { conversion in
            ConversionSheet(conversion: conversion) { text in
                model.canvas?.replaceStrokesWithText(conversion, text: text)
            }
        }
        .sheet(item: $model.sharedFile) { file in
            ShareSheet(items: [file.url])
                .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showPhotoPicker, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            photoItem = nil
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                    model.canvas?.insertImage(image)
                } else {
                    model.flash("Impossible de charger cette photo")
                }
            }
        }
        .fileImporter(isPresented: $showPDFImporter, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { importPDFPages(url) }
        }
        .fullScreenCover(isPresented: $showScanner) {
            DocumentScannerView { images in
                showScanner = false
                insertScannedPages(images)
            } onCancel: {
                showScanner = false
            }
            .ignoresSafeArea()
        }
        .alert("Renommer le carnet", isPresented: $showRename) {
            TextField("Titre", text: $renameText)
            Button("Renommer") { model.store.rename(notebookID, to: renameText) }
            Button("Annuler", role: .cancel) {}
        }
        .alert("Une erreur est survenue", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
        .confirmationDialog("Effacer toute l’encre de la page \(model.currentPageIndex + 1) ?",
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Effacer l’encre", role: .destructive) {
                model.canvas?.clearPage(at: model.currentPageIndex)
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button {
                close()
            } label: {
                Label("Bibliothèque", systemImage: "chevron.backward")
            }
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                model.canvas?.undo()
            } label: {
                Label("Annuler", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.canUndo)
            .keyboardShortcut("z", modifiers: .command)

            Button {
                model.canvas?.redo()
            } label: {
                Label("Rétablir", systemImage: "arrow.uturn.forward")
            }
            .disabled(!model.canRedo)
            .keyboardShortcut("z", modifiers: [.command, .shift])
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                if model.isSearching { model.endSearch() } else { model.isSearching = true }
            } label: {
                Label("Rechercher", systemImage: "magnifyingglass")
            }
            .keyboardShortcut("f", modifiers: .command)

            addMenu

            Button {
                model.showPageNavigator = true
            } label: {
                Label("Pages", systemImage: "square.grid.2x2")
            }

            moreMenu
        }
    }

    private var addMenu: some View {
        Menu {
            Button {
                model.canvas?.insertPage(after: model.currentPageIndex)
            } label: {
                Label("Nouvelle page", systemImage: "doc.badge.plus")
            }
            Button {
                model.templatePicker = TemplatePickerRequest(mode: .insert(after: model.currentPageIndex))
            } label: {
                Label("Page avec un modèle…", systemImage: "square.grid.3x3.square")
            }
            Divider()
            Button {
                showPhotoPicker = true
            } label: {
                Label("Photo", systemImage: "photo")
            }
            Button {
                model.select(.text)
                model.flash("Touchez la page pour placer le texte")
            } label: {
                Label("Zone de texte", systemImage: "character.textbox")
            }
            Divider()
            Button {
                showPDFImporter = true
            } label: {
                Label("Pages d’un PDF…", systemImage: "doc.richtext")
            }
            if VNDocumentCameraViewController.isSupported {
                Button {
                    showScanner = true
                } label: {
                    Label("Numériser des pages", systemImage: "doc.viewfinder")
                }
            }
        } label: {
            Label("Ajouter", systemImage: "plus")
        }
    }

    private var moreMenu: some View {
        Menu {
            Section {
                Toggle(isOn: Binding(get: { model.settings.fingerDrawing },
                                     set: { _ in model.toggleFingerDrawing() })) {
                    Label("Dessin au doigt", systemImage: "hand.draw")
                }
                Toggle(isOn: $model.alwaysSnapShapes) {
                    Label("Formes automatiques", systemImage: "circle.square")
                }
                Button {
                    model.focusMode = true
                } label: {
                    Label("Mode papier", systemImage: "rectangle.portrait")
                }
                Button {
                    model.canvas?.zoomToFitWidth()
                } label: {
                    Label("Ajuster à la largeur", systemImage: "arrow.left.and.right")
                }
            }
            Section("Page \(model.currentPageIndex + 1)") {
                Button {
                    model.canvas?.toggleBookmark(at: model.currentPageIndex)
                } label: {
                    Label(model.currentPage?.isBookmarked == true ? "Retirer le marque-page" : "Ajouter un marque-page",
                          systemImage: model.currentPage?.isBookmarked == true ? "bookmark.slash" : "bookmark")
                }
                Button {
                    model.templatePicker = TemplatePickerRequest(mode: .change(pageIndex: model.currentPageIndex))
                } label: {
                    Label("Modèle et papier…", systemImage: "doc.text")
                }
                Button {
                    model.copyCurrentPageText()
                } label: {
                    Label("Copier l’écriture en texte", systemImage: "text.viewfinder")
                }
                Button(role: .destructive) {
                    confirmClear = true
                } label: {
                    Label("Effacer l’encre de la page", systemImage: "eraser.line.dashed")
                }
            }
            Section("Coffre") {
                Button {
                    openLinkedNote()
                } label: {
                    Label("Note liée dans le coffre", systemImage: "doc.text")
                }
            }
            Section("Exporter") {
                Button {
                    model.exportPDF()
                } label: {
                    Label("Carnet entier (PDF)", systemImage: "square.and.arrow.up")
                }
                Button {
                    model.exportPDF(pageIndices: [model.currentPageIndex])
                } label: {
                    Label("Cette page (PDF)", systemImage: "doc")
                }
                Button {
                    model.exportCurrentPageImage()
                } label: {
                    Label("Cette page (image)", systemImage: "photo")
                }
            }
        } label: {
            Label("Plus", systemImage: "ellipsis")
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private var contextualBar: some View {
        if model.isSearching {
            NotebookSearchBar(model: model)
                .transition(.move(edge: .top).combined(with: .opacity))
        } else if model.selectedElementID != nil {
            ElementSelectionBar(model: model)
                .transition(.scale(scale: 0.9).combined(with: .opacity))
        } else if model.tool == .lasso && model.hasStrokeSelection {
            Button {
                Task { await model.canvas?.convertSelectionToText() }
            } label: {
                Label("Convertir en texte", systemImage: "text.viewfinder")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
        }
    }

    private var pageIndicator: some View {
        Button {
            model.showPageNavigator = true
        } label: {
            HStack(spacing: 6) {
                if model.currentPage?.isBookmarked == true {
                    Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                }
                Text("\(min(model.currentPageIndex + 1, max(model.pageCount, 1))) / \(max(model.pageCount, 1))")
                    .monospacedDigit()
                if model.zoomPercent != 100 {
                    Text("· \(model.zoomPercent) %")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .padding(.trailing, 16)
        .padding(.bottom, 14)
        .opacity(model.focusMode ? 0.35 : 1)
        .accessibilityLabel("Page \(model.currentPageIndex + 1) sur \(model.pageCount)")
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.callout.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(in: Capsule())
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var focusExitButton: some View {
        if model.focusMode {
            Button {
                model.focusMode = false
            } label: {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .glassEffect(.regular.interactive(), in: Circle())
            .opacity(0.55)
            .padding(16)
            .accessibilityLabel("Quitter le mode papier")
        }
    }

    @ViewBuilder
    private var busyOverlay: some View {
        if let message = model.busyMessage {
            VStack(spacing: 12) {
                ProgressView()
                Text(message).font(.callout)
            }
            .padding(24)
            .glassEffect(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    // MARK: Actions

    private func close() {
        model.canvas?.finish()
        onClose()
    }

    /// Closes the notebook and opens its Markdown note (page images + recognised text),
    /// where typed notes and [[links]] can be added around the generated part.
    private func openLinkedNote() {
        model.canvas?.finish()
        let id = notebookID
        onClose()
        Task {
            NotebookVaultBridge.shared.schedule(id)
            try? await Task.sleep(for: .seconds(3))
            if let path = NotebookVaultBridge.shared.companionPath(for: id) {
                AppRouter.shared.openNote(path)
            }
        }
    }

    private func importPDFPages(_ url: URL) {
        let files = model.store.files(for: notebookID)
        model.busyMessage = "Importation du PDF…"
        Task {
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let pages = try await Task.detached(priority: .userInitiated) {
                    try Importer.importPDF(from: url, into: files)
                }.value
                model.canvas?.insertPages(pages, after: model.currentPageIndex)
            } catch {
                model.errorMessage = error.localizedDescription
            }
            model.busyMessage = nil
        }
    }

    private func insertScannedPages(_ images: [UIImage]) {
        guard !images.isEmpty else { return }
        let files = model.store.files(for: notebookID)
        model.busyMessage = "Ajout des pages…"
        Task {
            let pages = await Task.detached(priority: .userInitiated) {
                Importer.imagePages(images, into: files)
            }.value
            model.canvas?.insertPages(pages, after: model.currentPageIndex)
            model.busyMessage = nil
        }
    }
}

// MARK: - NotebookCanvas (UIKit bridge)

struct NotebookCanvas: UIViewControllerRepresentable {
    let model: EditorModel
    let configuration: ToolConfiguration
    let topInset: CGFloat
    let bottomInset: CGFloat

    func makeUIViewController(context: Context) -> NotebookCanvasController {
        let controller = NotebookCanvasController(model: model)
        model.canvas = controller
        return controller
    }

    func updateUIViewController(_ controller: NotebookCanvasController, context: Context) {
        controller.apply(configuration)
        controller.setInsets(top: topInset, bottom: bottomInset)
    }

    static func dismantleUIViewController(_ controller: NotebookCanvasController, coordinator: ()) {
        controller.finish()
    }
}

// MARK: - Search bar

struct NotebookSearchBar: View {
    @Bindable var model: EditorModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher dans l’écriture, le texte et les PDF", text: $model.searchQuery)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused($focused)
                .onSubmit { model.runSearch() }
            if model.searchRunning {
                ProgressView().controlSize(.small)
            } else if !model.searchQuery.isEmpty {
                Text(model.searchHits.isEmpty ? "0" : "\(model.currentHit + 1)/\(model.searchHits.count)")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Button { model.nextHit(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(model.searchHits.isEmpty)
            Button { model.nextHit(1) } label: { Image(systemName: "chevron.down") }
                .disabled(model.searchHits.isEmpty)
            Button { model.endSearch() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: 560)
        .glassEffect(in: Capsule())
        .padding(.horizontal, 16)
        .onAppear { focused = true }
        .task(id: model.searchQuery) {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            model.runSearch()
        }
    }
}

// MARK: - Element selection bar

struct ElementSelectionBar: View {
    let model: EditorModel

    private var isText: Bool {
        guard let id = model.selectedElementID, let pages = model.notebook?.pages else { return false }
        return pages.lazy.flatMap(\.elements).first { $0.id == id }?.kind == .text
    }

    var body: some View {
        HStack(spacing: 2) {
            if isText {
                item("Modifier", "pencil") { model.canvas?.editSelectedText() }
            }
            item("Dupliquer", "plus.square.on.square") { model.canvas?.duplicateSelectedElement() }
            item("Premier plan", "square.3.layers.3d.top.filled") { model.canvas?.bringSelectedElementToFront() }
            item("Supprimer", "trash", destructive: true) { model.canvas?.deleteSelectedElement() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(in: Capsule())
    }

    private func item(_ title: String, _ symbol: String, destructive: Bool = false,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .labelStyle(.titleAndIcon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(destructive ? Color.red : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}
