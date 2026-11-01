import SwiftUI

// MARK: - NotebookCell (library grid item)

struct NotebookCell: View {
    let notebook: Notebook
    var coverHeight: CGFloat = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotebookCoverView(notebook: notebook)
                .frame(height: coverHeight, alignment: .bottom)
                .frame(maxWidth: .infinity, alignment: .bottom)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(notebook.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if notebook.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private var subtitle: String {
        let count = notebook.pages.count
        let pages = count == 1 ? "1 page" : "\(count) pages"
        return "\(pages) · \(notebook.modifiedAt.formatted(.relative(presentation: .named)))"
    }
}

// MARK: - NotebookCoverView

struct NotebookCoverView: View {
    let notebook: Notebook

    private var aspect: CGFloat {
        guard let first = notebook.pages.first, first.height > 0 else { return 0.72 }
        return CGFloat(first.width / first.height)
    }

    var body: some View {
        Group {
            if let cover = notebook.cover {
                CoverArt(cover: cover, title: notebook.title)
                    .aspectRatio(aspect, contentMode: .fit)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 3,
                                                      bottomTrailingRadius: 9, topTrailingRadius: 9,
                                                      style: .continuous))
            } else if let first = notebook.pages.first {
                PageThumbnailView(page: first, notebookID: notebook.id, maxPixel: 440)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .aspectRatio(aspect, contentMode: .fit)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 6, x: 0, y: 4)
        .overlay(alignment: .bottomLeading) {
            if notebook.origin == .goodNotes {
                Text("GoodNotes")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(6)
                    .accessibilityLabel("Importé de GoodNotes")
            }
        }
    }
}

// MARK: - CoverArt

struct CoverArt: View {
    let cover: CoverStyle
    let title: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                LinearGradient(colors: [Color(rgba: cover.base), Color(rgba: cover.base).opacity(0.82)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                // Linen grain
                LinearGradient(colors: [.white.opacity(0.10), .clear, .black.opacity(0.10)],
                               startPoint: .top, endPoint: .bottom)
                // Spine
                Rectangle()
                    .fill(.black.opacity(0.16))
                    .frame(width: w * 0.075)
                Rectangle()
                    .fill(.white.opacity(0.22))
                    .frame(width: 1)
                    .offset(x: w * 0.075)
                // Elastic band
                Rectangle()
                    .fill(.black.opacity(0.22))
                    .frame(width: max(3, w * 0.03))
                    .offset(x: w * 0.86)
                // Label
                if !title.isEmpty {
                Text(title)
                    .font(.system(size: max(10, w * 0.082), weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .foregroundStyle(Color(white: 0.16))
                    .padding(.horizontal, w * 0.06)
                    .padding(.vertical, h * 0.035)
                    .frame(width: w * 0.62)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Color(red: 0.985, green: 0.975, blue: 0.95))
                            .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
                    )
                    .position(x: w * 0.075 + (w * 0.785) / 2, y: h * 0.32)
                }
            }
        }
    }
}

// MARK: - CoverPicker

struct CoverPicker: View {
    @Binding var selection: CoverStyle?
    var allowsNone = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                if allowsNone {
                    Button {
                        selection = nil
                    } label: {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                            .foregroundStyle(.secondary)
                            .frame(width: 46, height: 62)
                            .overlay(Image(systemName: "doc").foregroundStyle(.secondary))
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selection == nil ? Color.accentColor : .clear, lineWidth: 2.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Sans couverture")
                }
                ForEach(CoverStyle.allCases) { cover in
                    Button {
                        selection = cover
                    } label: {
                        CoverArt(cover: cover, title: "")
                            .frame(width: 46, height: 62)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .padding(3)
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(selection == cover ? Color.accentColor : .clear, lineWidth: 2.5)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(cover.label)
                }
            }
            .padding(.vertical, 4)
        }
    }
}
