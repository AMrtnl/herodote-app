import SwiftUI
import PencilKit

// MARK: - PageNavigatorView (thumbnail grid and outline: jump, name, reorder, insert, duplicate, delete)

enum PageFilter: Hashable {
    case all, bookmarks, outline
}

struct PageNavigatorView: View {
    let model: EditorModel

    @Environment(\.dismiss) private var dismiss
    @State private var drawings: [UUID: PKDrawing] = [:]
    @State private var filter: PageFilter = .all
    @State private var naming: PageTitleRequest?
    @State private var nameText = ""
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
            .filter { filter != .bookmarks || $0.page.isBookmarked }
    }

    /// Named pages, plus bookmarked ones so the outline is never empty when there are bookmarks.
    private var outline: [PageItem] {
        pages.enumerated()
            .map { PageItem(index: $0.offset, page: $0.element) }
            .filter { !$0.page.title.isEmpty || $0.page.isBookmarked }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filter == .outline {
                    outlineList
                } else {
                    grid
                }
            }
            .navigationTitle("Pages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Afficher", selection: $filter) {
                        Text("Pages").tag(PageFilter.all)
                        Text("Marque-pages").tag(PageFilter.bookmarks)
                        Text("Plan").tag(PageFilter.outline)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                if !model.isReadOnly {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            model.canvas?.insertPage(after: pages.count - 1)
                            refresh()
                        } label: {
                            Label("Ajouter une page à la fin", systemImage: "plus")
                        }
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
            .alert("Nommer la page \((naming?.pageIndex ?? 0) + 1)", isPresented: Binding(
                get: { naming != nil },
                set: { if !$0 { naming = nil } }
            )) {
                TextField("Titre de la page", text: $nameText)
                Button("OK") {
                    if let request = naming { model.canvas?.setPageTitle(nameText, at: request.pageIndex) }
                    naming = nil
                }
                Button("Annuler", role: .cancel) { naming = nil }
            }
        }
        .onAppear { refresh() }
    }

    private var grid: some View {
        ScrollView {
            if items.isEmpty {
                ContentUnavailableView("Aucun marque-page",
                                       systemImage: "bookmark",
                                       description: Text(model.isReadOnly
                                                         ? "Les marque-pages posés sur iPad apparaissent ici."
                                                         : "Ajoutez des marque-pages depuis le menu ⋯ de l’éditeur ou en touchant longuement une page."))
                    .padding(.top, 60)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 128, maximum: 180), spacing: 20)], spacing: 24) {
                ForEach(items) { item in
                    cell(index: item.index, page: item.page)
                }
            }
            .padding(20)
        }
    }

    @ViewBuilder
    private var outlineList: some View {
        if outline.isEmpty {
            ContentUnavailableView {
                Label("Aucune page nommée", systemImage: "list.bullet.indent")
            } description: {
                Text(model.isReadOnly
                     ? "Les titres de pages donnés sur iPad forment le plan du carnet."
                     : "Touchez longuement une page › Nommer la page, ou menu ⋯ › Nommer la page. Les pages nommées forment le plan du carnet.")
            }
        } else {
            List {
                Section {
                    ForEach(outline) { item in
                        outlineRow(item)
                    }
                } footer: {
                    Text("Les pages nommées forment le plan du carnet. Leurs titres deviennent les intertitres de la note du carnet dans le coffre (« ## Page 3 — Introduction »).")
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    private func outlineRow(_ item: PageItem) -> some View {
        Button {
            model.canvas?.scrollToPage(item.index, animated: false)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                PageThumbnailView(page: item.page, notebookID: model.notebookID,
                                  drawing: drawings[item.page.id], maxPixel: 120)
                    .frame(width: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.page.title.isEmpty ? "Page \(item.index + 1)" : item.page.title)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                    Text(item.page.title.isEmpty ? "Marque-page" : "Page \(item.index + 1)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.page.isBookmarked {
                    Image(systemName: "bookmark.fill").foregroundStyle(.orange)
                }
                if item.index == model.currentPageIndex {
                    Image(systemName: "eye").foregroundStyle(Color.accentColor)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions {
            if !model.isReadOnly {
                Button {
                    nameText = item.page.title
                    naming = PageTitleRequest(pageIndex: item.index, title: item.page.title)
                } label: {
                    Label("Renommer", systemImage: "pencil")
                }
                .tint(Color.accentColor)
            }
        }
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
            VStack(spacing: 1) {
                Text("\(index + 1)")
                    .font(.footnote.weight(isCurrent ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                if !page.title.isEmpty {
                    Text(page.title)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            model.canvas?.scrollToPage(index, animated: false)
            dismiss()
        }
        .contextMenu {
            if model.isReadOnly {
                Button {
                    model.exportPDF(pageIndices: [index])
                    dismiss()
                } label: {
                    Label("Exporter la page", systemImage: "square.and.arrow.up")
                }
            } else {
                editingMenu(index: index, page: page)
            }
        }
        .modifier(PageReorderModifier(enabled: !model.isReadOnly, page: page, index: index, pages: pages,
                                      model: model, drawings: drawings, dropTarget: $dropTarget, refresh: refresh))
    }

    @ViewBuilder
    private func editingMenu(index: Int, page: NotebookPage) -> some View {
        Button {
            nameText = page.title
            naming = PageTitleRequest(pageIndex: index, title: page.title)
        } label: {
            Label(page.title.isEmpty ? "Nommer la page…" : "Renommer la page…", systemImage: "list.bullet.indent")
        }
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
}

// MARK: - Drag to reorder (editing only)

private struct PageReorderModifier: ViewModifier {
    let enabled: Bool
    let page: NotebookPage
    let index: Int
    let pages: [NotebookPage]
    let model: EditorModel
    let drawings: [UUID: PKDrawing]
    @Binding var dropTarget: UUID?
    let refresh: () -> Void

    func body(content: Content) -> some View {
        if enabled {
            content
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
        } else {
            content
        }
    }
}
