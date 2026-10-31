import SwiftUI
import UIKit

// MARK: - Template preview images (rendered with the real page renderer)

enum TemplatePreviewCache {
    private static var images: [String: UIImage] = [:]

    static func image(_ template: PageTemplate, paper: PaperStyle, landscape: Bool) -> UIImage {
        let key = "\(template.rawValue)-\(paper.rawValue)-\(landscape)"
        if let cached = images[key] { return cached }
        let page = NotebookPage(size: PageFormat.a4.size(landscape: landscape),
                                background: .template(template), paper: paper)
        let files = NotebookFiles(directory: FileManager.default.temporaryDirectory)
        let image = PageRenderer.renderBackground(page: page, files: files, region: page.bounds, scale: 0.5)
        images[key] = image
        return image
    }
}

struct TemplatePreview: View {
    let template: PageTemplate
    let paper: PaperStyle
    var landscape = false

    var body: some View {
        Image(uiImage: TemplatePreviewCache.image(template, paper: paper, landscape: landscape))
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
    }
}

// MARK: - Template grid

struct TemplateGrid: View {
    @Binding var selection: PageTemplate
    let paper: PaperStyle
    var landscape = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92, maximum: 120), spacing: 14)], spacing: 16) {
            ForEach(PageTemplate.allCases) { template in
                Button {
                    selection = template
                } label: {
                    VStack(spacing: 6) {
                        TemplatePreview(template: template, paper: paper, landscape: landscape)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(selection == template ? Color.accentColor : .clear, lineWidth: 2.5)
                                    .padding(-4)
                            }
                        Text(template.label)
                            .font(.caption)
                            .foregroundStyle(selection == template ? Color.accentColor : Color.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == template ? .isSelected : [])
            }
        }
    }
}

// MARK: - Paper colour picker

struct PaperPicker: View {
    @Binding var selection: PaperStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                ForEach(PaperStyle.allCases) { paper in
                    Button {
                        selection = paper
                    } label: {
                        VStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(Color(rgba: paper.fill))
                                .frame(width: 44, height: 44)
                                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                                .overlay {
                                    if selection == paper {
                                        Image(systemName: "checkmark")
                                            .font(.footnote.weight(.bold))
                                            .foregroundStyle(paper.isDark ? Color.white : Color.black)
                                    }
                                }
                                .padding(3)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .strokeBorder(selection == paper ? Color.accentColor : .clear, lineWidth: 2)
                                }
                            Text(paper.label)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 4)
        }
    }
}

// MARK: - Template picker sheet (insert a page / change a page)

struct TemplatePickerSheet: View {
    let model: EditorModel
    let mode: TemplatePickerMode

    @Environment(\.dismiss) private var dismiss
    @State private var template: PageTemplate
    @State private var paper: PaperStyle
    @State private var applyToAll = false

    init(model: EditorModel, mode: TemplatePickerMode) {
        self.model = model
        self.mode = mode
        let pages = model.notebook?.pages ?? []
        let referenceIndex: Int
        switch mode {
        case .insert(let after): referenceIndex = after
        case .change(let index): referenceIndex = index
        }
        let reference = pages.indices.contains(referenceIndex) ? pages[referenceIndex] : nil
        _template = State(initialValue: reference?.background.template ?? model.notebook?.defaultTemplate ?? .lined)
        _paper = State(initialValue: reference?.paper ?? model.notebook?.defaultPaper ?? .white)
    }

    private var isInsert: Bool {
        if case .insert = mode { return true }
        return false
    }

    /// Pages backed by a PDF or an image keep their background; only the paper tint applies.
    private var changesFixedBackground: Bool {
        guard case .change(let index) = mode, let pages = model.notebook?.pages, pages.indices.contains(index) else { return false }
        return !pages[index].background.isTemplate
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if changesFixedBackground {
                        Label("Cette page provient d’un PDF ou d’une image : son fond est conservé.",
                              systemImage: "info.circle")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Modèle").font(.headline)
                        TemplateGrid(selection: $template, paper: paper)
                    }
                    Text("Papier").font(.headline)
                    PaperPicker(selection: $paper)
                    if !isInsert {
                        Toggle("Appliquer à toutes les pages", isOn: $applyToAll)
                    }
                }
                .padding(20)
            }
            .navigationTitle(isInsert ? "Nouvelle page" : "Modèle de page")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Annuler") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isInsert ? "Ajouter" : "Appliquer") {
                        switch mode {
                        case .insert(let after):
                            model.canvas?.insertPage(after: after, template: template, paper: paper)
                        case .change(let index):
                            model.canvas?.setAppearance(template: changesFixedBackground ? nil : template,
                                                        paper: paper, pageIndex: index, allPages: applyToAll)
                        }
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
