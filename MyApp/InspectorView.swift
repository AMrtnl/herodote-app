import SwiftUI

// MARK: - SheetInspector (unified right panel)

struct SheetInspector: View {
    @Binding var sheet: WritingSheet
    let allSheets: [WritingSheet]
    let state: EditorState
    var onNavigate: (UUID) -> Void

    var body: some View {
        List {
            outlineSection
            statsSection
            progressSection
            keywordsSection
            linksSection
            notesSection
            annotationsSection
        }
        .listStyle(.inset)
        .inspectorColumnWidth(min: 220, ideal: 260, max: 340)
    }

    // MARK: Outline (from Markdown headings)

    private var outlineSection: some View {
        // Prefer the live editor text — sheet.plainText decodes the whole
        // archive on every access, too costly per keystroke with the inspector open
        let text = state.textView?.string ?? sheet.plainText
        let headings = MarkdownHighlighter.headings(in: text)
        return Section {
            if headings.isEmpty {
                Text("Aucun titre — commencez une ligne par « # »")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(headings.enumerated()), id: \.offset) { _, heading in
                    Button {
                        state.scrollTo(range: NSRange(location: heading.range.location, length: 0))
                    } label: {
                        Text(heading.title)
                            .font(heading.level == 1 ? .callout.weight(.semibold) : .callout)
                            .lineLimit(1)
                            .padding(.leading, CGFloat(heading.level - 1) * 12)
                    }
                    .buttonStyle(.plain)
                }
            }
        } header: {
            Label("Plan", systemImage: "list.bullet.indent")
        }
    }

    // MARK: Stats

    private var statsSection: some View {
        Section {
            LabeledContent("Mots", value: "\(sheet.wordCount)")
            LabeledContent("Caractères", value: "\(sheet.characterCount)")
            LabeledContent("Paragraphes", value: "\(sheet.paragraphCount)")
            LabeledContent("Lecture", value: "\(sheet.readingTimeMinutes) min")
            LabeledContent("Créé", value: sheet.createdAt.formatted(date: .abbreviated, time: .omitted))
            LabeledContent("Modifié", value: sheet.modifiedAt.formatted(date: .abbreviated, time: .shortened))
        } header: {
            Label("Statistiques", systemImage: "chart.bar")
        }
    }

    // MARK: Progress

    private var progressSection: some View {
        Section {
            if let goal = sheet.wordGoal {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("\(sheet.wordCount) / \(goal) mots")
                            .font(.callout)
                        Spacer()
                        Text("\(Int(sheet.progressFraction * 100)) %")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: sheet.progressFraction)
                        .tint(sheet.progressFraction >= 1.0 ? .green : .accentColor)
                }
                Button("Supprimer l'objectif", role: .destructive) {
                    sheet.wordGoal = nil
                }
                .font(.caption)
            } else {
                GoalSetter { goal in sheet.wordGoal = goal }
            }
        } header: {
            Label("Progression", systemImage: "target")
        }
    }

    // MARK: Keywords

    private var keywordsSection: some View {
        Section {
            KeywordsEditor(keywords: $sheet.keywords)
        } header: {
            Label("Mots-clés", systemImage: "tag")
        }
    }

    // MARK: Links

    private var linksSection: some View {
        let outIDs = sheet.outgoingLinkIDs
        let outSheets = outIDs.compactMap { id in allSheets.first { $0.id == id } }
        let inSheets = allSheets.filter { $0.id != sheet.id && $0.outgoingLinkIDs.contains(sheet.id) }

        return Section {
            if outSheets.isEmpty && inSheets.isEmpty {
                Text("Aucun lien")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !outSheets.isEmpty {
                ForEach(outSheets) { target in
                    Button {
                        onNavigate(target.id)
                    } label: {
                        Label(target.title, systemImage: "arrow.right.doc.on.clipboard")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }
            }
            if !inSheets.isEmpty {
                Divider()
                Text("Liens entrants")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                ForEach(inSheets) { source in
                    Button {
                        onNavigate(source.id)
                    } label: {
                        Label(source.title, systemImage: "arrow.left.doc.on.clipboard")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.purple)
                }
            }
        } header: {
            Label("Liens (\(outSheets.count + inSheets.count))", systemImage: "link")
        }
    }

    // MARK: Notes

    private var notesSection: some View {
        Section {
            TextEditor(text: $sheet.authorNotes)
                .font(.callout)
                .frame(minHeight: 80)
                .overlay(alignment: .topLeading) {
                    if sheet.authorNotes.isEmpty {
                        Text("Notes de l'auteur…")
                            .foregroundStyle(.placeholder)
                            .font(.callout)
                            .padding(.top, 4)
                            .padding(.leading, 4)
                            .allowsHitTesting(false)
                    }
                }
        } header: {
            Label("Notes", systemImage: "note.text")
        }
    }

    // MARK: Annotations (comments)

    private var annotationsSection: some View {
        let active = sheet.comments.filter { !$0.resolved }
        let resolved = sheet.comments.filter { $0.resolved }

        return Section {
            if sheet.comments.isEmpty {
                Text("Aucune annotation")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(active) { comment in
                CommentRow(comment: comment) { updated in updateComment(updated) }
            }
            if !resolved.isEmpty {
                DisclosureGroup("Résolus (\(resolved.count))") {
                    ForEach(resolved) { comment in
                        CommentRow(comment: comment) { updated in updateComment(updated) }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        } header: {
            Label("Annotations (\(active.count))", systemImage: "text.bubble")
        }
    }

    private func updateComment(_ comment: WritingComment) {
        if let idx = sheet.comments.firstIndex(where: { $0.id == comment.id }) {
            sheet.comments[idx] = comment
        }
    }
}

// MARK: - CommentRow

struct CommentRow: View {
    let comment: WritingComment
    var onUpdate: (WritingComment) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                var c = comment; c.resolved.toggle(); onUpdate(c)
            } label: {
                Image(systemName: comment.resolved ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(comment.resolved ? Color.green : Color.secondary)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(comment.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                Text(comment.createdAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .opacity(comment.resolved ? 0.5 : 1)
    }
}

// MARK: - GoalSetter

struct GoalSetter: View {
    var onSet: (Int) -> Void
    @State private var input = ""

    var body: some View {
        HStack {
            TextField("Objectif (mots)", text: $input)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commit() }
            Button("OK") { commit() }
                .disabled(goalValue == nil)
        }
        .font(.callout)
    }

    private var goalValue: Int? { Int(input.trimmingCharacters(in: .whitespaces)).flatMap { $0 > 0 ? $0 : nil } }

    private func commit() {
        if let g = goalValue { onSet(g); input = "" }
    }
}

// MARK: - KeywordsEditor

struct KeywordsEditor: View {
    @Binding var keywords: [String]
    @State private var newKeyword = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Chips
            if !keywords.isEmpty {
                FlowLayout(spacing: 4) {
                    ForEach(keywords, id: \.self) { kw in
                        HStack(spacing: 2) {
                            Text(kw).font(.caption)
                            Button { keywords.removeAll { $0 == kw } } label: {
                                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
            }
            // Add field
            HStack {
                TextField("Ajouter un mot-clé…", text: $newKeyword)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .onSubmit { addKeyword() }
                Button(action: addKeyword) {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(newKeyword.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func addKeyword() {
        let kw = newKeyword.trimmingCharacters(in: .whitespaces).lowercased()
        guard !kw.isEmpty, !keywords.contains(kw) else { return }
        keywords.append(kw)
        newKeyword = ""
    }
}

// MARK: - FlowLayout (wrapping HStack for keyword chips)

struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        layout(subviews: subviews, maxWidth: proposal.replacingUnspecifiedDimensions().width).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(subviews: subviews, maxWidth: bounds.width)
        for (idx, frame) in result.frames.enumerated() {
            subviews[idx].place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(frame.size)
            )
        }
    }

    private struct LayoutResult { var size: CGSize; var frames: [CGRect] }

    private func layout(subviews: Subviews, maxWidth: CGFloat) -> LayoutResult {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth && x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return LayoutResult(
            size: CGSize(width: maxWidth, height: y + rowHeight),
            frames: frames
        )
    }
}
