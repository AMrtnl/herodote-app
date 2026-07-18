import SwiftUI

// MARK: - EditorDetailView

struct EditorDetailView: View {
    @Binding var sheet: WritingSheet
    let allSheets: [WritingSheet]
    var onNavigate: (UUID) -> Void

    @State private var state = EditorState()
    @State private var showInspector  = false
    @State private var showLinkPicker = false
    @State private var showAddComment = false
    @State private var commentDraft   = ""

    var body: some View {
        // AppSettings.shared is @Observable — SwiftUI tracks reads automatically
        let settings = AppSettings.shared
        ZStack(alignment: .top) {
            Color(NSColor.textBackgroundColor).ignoresSafeArea()

            RichTextEditor(sheet: $sheet, state: state, onNavigate: onNavigate)

            if state.hasSelection {
                FormatBar(state: state, onComment: { showAddComment = true }, onLink: { showLinkPicker = true })
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.8), value: state.hasSelection)
        .focusedSceneValue(\.editorState, state)
        .navigationTitle(sheet.title)
        .toolbar {
            // Word count
            ToolbarItem(placement: .status) {
                Text("\(state.wordCount) mot\(state.wordCount > 1 ? "s" : "")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Writing mode — hides sidebar + typewriter centering + paragraph dimming
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.toggleWritingMode()
                } label: {
                    Image(systemName: settings.writingMode ? "pencil.line" : "pencil")
                }
                .help(settings.writingMode ? "Quitter le mode écriture" : "Mode écriture")
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }

            // Link picker
            ToolbarItem(placement: .primaryAction) {
                Button { showLinkPicker = true } label: {
                    Image(systemName: "link.badge.plus")
                }
                .help("Insérer un lien (⌘K)")
                .keyboardShortcut("k", modifiers: .command)
            }

            // Inspector
            ToolbarItem(placement: .primaryAction) {
                Button { showInspector.toggle() } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Inspecteur")
            }
        }
        .inspector(isPresented: $showInspector) {
            SheetInspector(
                sheet: $sheet,
                allSheets: allSheets,
                state: state,
                onNavigate: onNavigate
            )
        }
        .sheet(isPresented: $showLinkPicker) {
            LinkPicker(allSheets: allSheets, currentSheetID: sheet.id) { targetID, label in
                state.insertLink(targetID: targetID, label: label)
                showLinkPicker = false
            }
        }
        .sheet(isPresented: $showAddComment) {
            AddCommentSheet(draft: $commentDraft) { text in
                guard let range = state.selectedRange else { return }
                let comment = WritingComment(rangeLocation: range.location, rangeLength: range.length, text: text)
                sheet.comments.append(comment)
                state.highlightCommentRange(range)
                commentDraft = ""
                showAddComment = false
            } onCancel: {
                commentDraft = ""
                showAddComment = false
            }
        }
    }
}

// MARK: - FormatBar

struct FormatBar: View {
    let state: EditorState
    var onComment: () -> Void
    var onLink: () -> Void

    var body: some View {
        GlassEffectContainer {
            HStack(spacing: 2) {
                fBtn("bold")      { state.bold() }
                fBtn("italic")    { state.italic() }
                fBtn("underline") { state.underline() }
                sep
                fBtn("textformat.size.larger") { state.heading(1) }
                fBtn("textformat.size")        { state.heading(2) }
                fBtn("textformat")             { state.bodyStyle() }
                sep
                fBtn("link")        { onLink() }
                fBtn("text.bubble") { onComment() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassEffect(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
    }

    private func fBtn(_ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 32, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var sep: some View {
        Color.primary.opacity(0.15).frame(width: 1, height: 18).padding(.horizontal, 3)
    }
}

// MARK: - AddCommentSheet

struct AddCommentSheet: View {
    @Binding var draft: String
    var onAdd: (String) -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Text("Ajouter une annotation").font(.title3.bold())
            TextEditor(text: $draft)
                .font(.body)
                .frame(width: 320, height: 100)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            HStack(spacing: 12) {
                Button("Annuler", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Ajouter") { onAdd(draft) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
    }
}
