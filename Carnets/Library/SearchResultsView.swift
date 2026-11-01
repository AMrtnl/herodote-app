import SwiftUI

// MARK: - SearchResultsView (titles, handwriting, PDF text, text boxes)

struct SearchResultsView: View {
    let query: String
    var onOpen: (UUID, Int?) -> Void

    @Environment(NotebookStore.self) private var store

    private struct ResultGroup: Identifiable {
        let notebook: Notebook
        let matches: [SearchMatch]
        var id: UUID { notebook.id }
    }

    private var groups: [ResultGroup] {
        let matches = LibrarySearch.search(query, in: store.notebooks)
        return store.notebooks
            .sorted { $0.modifiedAt > $1.modifiedAt }
            .compactMap { notebook in
                let own = matches.filter { $0.notebookID == notebook.id }
                return own.isEmpty ? nil : ResultGroup(notebook: notebook, matches: own)
            }
    }

    var body: some View {
        let groups = self.groups
        List {
            if groups.isEmpty {
                ContentUnavailableView.search(text: query)
                    .listRowBackground(Color.clear)
            }
            ForEach(groups) { group in
                Section(group.notebook.title) {
                    ForEach(group.matches) { match in
                        Button {
                            onOpen(match.notebookID, match.pageIndex)
                        } label: {
                            row(match, notebook: group.notebook)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ match: SearchMatch, notebook: Notebook) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let index = match.pageIndex, notebook.pages.indices.contains(index) {
                    PageThumbnailView(page: notebook.pages[index], notebookID: notebook.id, maxPixel: 160)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                        .shadow(color: .black.opacity(0.15), radius: 1.5, y: 1)
                } else {
                    NotebookCoverView(notebook: notebook)
                }
            }
            .frame(width: 46, height: 60)

            VStack(alignment: .leading, spacing: 4) {
                Text(label(for: match))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(highlighted(match.snippet))
                    .font(.callout)
                    .lineLimit(3)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func label(for match: SearchMatch) -> String {
        let page = match.pageIndex.map { "Page \($0 + 1) · " } ?? ""
        switch match.source {
        case .title:       return "Titre du carnet"
        case .handwriting: return page + "Écriture manuscrite"
        case .pdfText:     return page + "Texte de la page (PDF ou écriture importée)"
        case .typedText:   return page + "Zone de texte"
        }
    }

    private func highlighted(_ snippet: String) -> AttributedString {
        var attributed = AttributedString(snippet)
        if let range = attributed.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
            attributed[range].font = .callout.bold()
            attributed[range].backgroundColor = Color.yellow.opacity(0.35)
        }
        return attributed
    }
}
