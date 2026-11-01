import SwiftUI

// MARK: - NewNotebookSheet

struct NewNotebookSheet: View {
    var folderID: UUID?
    var onCreate: (Notebook) -> Void

    @Environment(NotebookStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var cover: CoverStyle? = .ink
    @State private var template: PageTemplate
    @State private var paper: PaperStyle
    @State private var format: PageFormat
    @State private var landscape = false
    @FocusState private var titleFocused: Bool

    init(folderID: UUID?, onCreate: @escaping (Notebook) -> Void) {
        self.folderID = folderID
        self.onCreate = onCreate
        let settings = CarnetsSettings.shared
        _template = State(initialValue: settings.defaultTemplate)
        _paper = State(initialValue: settings.defaultPaper)
        _format = State(initialValue: settings.defaultFormat)
        _cover = State(initialValue: CoverStyle.allCases.randomElement() ?? .ink)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .top, spacing: 20) {
                        preview
                            .frame(width: 120, height: 160)
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Carnet sans titre", text: $title)
                                .font(.title3.weight(.semibold))
                                .textFieldStyle(.plain)
                                .submitLabel(.done)
                                .focused($titleFocused)
                                .onSubmit(create)
                            Divider()
                            Text("Couverture").font(.subheadline).foregroundStyle(.secondary)
                            CoverPicker(selection: $cover)
                        }
                    }

                    section("Modèle de page") {
                        TemplateGrid(selection: $template, paper: paper, landscape: landscape)
                    }

                    section("Papier") {
                        PaperPicker(selection: $paper)
                    }

                    section("Format") {
                        Picker("Format", selection: $format) {
                            ForEach(PageFormat.allCases) { format in
                                Text(format.label).tag(format)
                            }
                        }
                        .pickerStyle(.segmented)
                        Picker("Orientation", selection: $landscape) {
                            Label("Portrait", systemImage: "rectangle.portrait").tag(false)
                            Label("Paysage", systemImage: "rectangle").tag(true)
                        }
                        .pickerStyle(.segmented)
                    }
                }
                .padding(24)
            }
            .navigationTitle("Nouveau carnet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Créer", action: create)
                }
            }
            .onAppear { titleFocused = true }
        }
    }

    @ViewBuilder
    private var preview: some View {
        let size = format.size(landscape: landscape)
        let ratio = size.width / size.height
        if let cover {
            CoverArt(cover: cover, title: title.isEmpty ? "Carnet" : title)
                .aspectRatio(ratio, contentMode: .fit)
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                                  bottomTrailingRadius: 8, topTrailingRadius: 8,
                                                  style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            TemplatePreview(template: template, paper: paper, landscape: landscape)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
    }

    private func create() {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let notebook = store.createNotebook(title: trimmed.isEmpty ? "Carnet sans titre" : trimmed,
                                            cover: cover, template: template, paper: paper,
                                            format: format, landscape: landscape, folderID: folderID)
        dismiss()
        onCreate(notebook)
    }
}
