import SwiftUI
import PencilKit

// MARK: - PageNavigatorView (thumbnail grid: jump, reorder, insert, duplicate, delete)

struct PageNavigatorView: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @State private var drawings: [UUID: PKDrawing] = [:]
    @State private var bookmarksOnly = false
    @State private var pendingDelete: Int?
    @State private var templateRequest: TemplatePickerRequest?
    @State private var dropTarget: UUID?

    private var pages: [NotebookPage] { model.notebook?.pages ?? [] }

    private struct PageItem: Identifiable {
        let index: Int
        let page: NotebookPage
        var id: UUID { page.id }
    }

    private var items: [PageItem] {
        pages.enumerated()
            .map { PageItem(index: $0.offset, page: $0.element) }
            .filter { !bookmarksOnly || $0.page.isBookmarked }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if items.isEmpty {
                    ContentUnavailableView("Aucun marque-page",
                                           systemImage: "bookmark",
                                           description: Text("Ajoutez des marque-pages depuis le menu ⋯ de l’éditeur ou en touchant longuement une page."))
                        .padding(.top, 60)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 20)], spacing: 24) {
                    ForEach(items) { item in
                        cell(index: item.index, page: item.page)
                    }
                }
                .padding(20)
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Afficher", selection: $bookmarksOnly) {
                        Text("Toutes").tag(false)
                        Text("Marque-pages").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 240)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        model.canvas?.insertPage(after: pages.count - 1)
                        refresh()
                    } label: {
                        Label("Ajouter une page à la fin", systemImage: "plus")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .confirmationDialog("Supprimer cette page ?", isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ), titleVisibility: .visible) {
                Button("Supprimer la page", role: .destructive) {
                    if let index = pendingDelete {
                        model.canvas?.deletePage(at: index)
                        refresh()
                    }
                    pendingDelete = nil
                }
            } message: {
                Text("L’encre, le texte et les images de la page seront supprimés.")
            }
            .sheet(item: $templateRequest) { request in
                TemplatePickerSheet(model: model, mode: request.mode)
            }
        }
        .onAppear { refresh() }
    }

    private func refresh() {
        drawings = model.canvas?.drawingsSnapshot() ?? drawings
    }

    private func cell(index: Int, page: NotebookPage) -> some View {
        let isCurrent = index == model.currentPageIndex
        return VStack(spacing: 8) {
            PageThumbnailView(page: page, notebookID: model.notebookID, drawing: drawings[page.id], maxPixel: 340)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(isCurrent ? Color.accentColor : (dropTarget == page.id ? Color.accentColor.opacity(0.5) : .clear),
                                      lineWidth: 3)
                        .padding(-4)
                }
                .overlay(alignment: .topTrailing) {
                    if page.isBookmarked {
                        Image(systemName: "bookmark.fill")
                            .font(.title3)
                            .foregroundStyle(.orange)
                            .shadow(radius: 1)
                            .offset(x: -6, y: -2)
                    }
                }
            Text("\(index + 1)")
                .font(.footnote.weight(isCurrent ? .bold : .regular).monospacedDigit())
                .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.canvas?.scrollToPage(index, animated: false)
            dismiss()
        }
        .contextMenu {
            Button {
                model.canvas?.toggleBookmark(at: index)
            } label: {
                Label(page.isBookmarked ? "Retirer le marque-page" : "Marque-page",
                      systemImage: page.isBookmarked ? "bookmark.slash" : "bookmark")
            }
            Button {
                model.canvas?.insertPage(after: index - 1)
                refresh()
            } label: {
                Label("Insérer une page avant", systemImage: "arrow.up.doc")
            }
            Button {
                model.canvas?.insertPage(after: index)
                refresh()
            } label: {
                Label("Insérer une page après", systemImage: "arrow.down.doc")
            }
            Button {
                model.canvas?.duplicatePage(at: index)
                refresh()
            } label: {
                Label("Dupliquer", systemImage: "plus.square.on.square")
            }
            Button {
                templateRequest = TemplatePickerRequest(mode: .change(pageIndex: index))
            } label: {
                Label("Modèle et papier…", systemImage: "doc.text")
            }
            Button {
                model.exportPDF(pageIndices: [index])
                dismiss()
            } label: {
                Label("Exporter la page", systemImage: "square.and.arrow.up")
            }
            Divider()
            Button(role: .destructive) {
                pendingDelete = index
            } label: {
                Label("Supprimer", systemImage: "trash")
            }
        }
        .draggable(page.id.uuidString) {
            PageThumbnailView(page: page, notebookID: model.notebookID, drawing: drawings[page.id], maxPixel: 200)
                .frame(width: 90)
        }
        .dropDestination(for: String.self) { identifiers, _ in
            guard let raw = identifiers.first, let id = UUID(uuidString: raw),
                  let source = pages.firstIndex(where: { $0.id == id }), source != index else { return false }
            model.canvas?.movePage(from: source, to: index)
            refresh()
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? page.id : (dropTarget == page.id ? nil : dropTarget)
        }
    }
}
