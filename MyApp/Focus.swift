import SwiftUI

// MARK: - FocusedValue for EditorState
// Lets menu commands reach the active editor's EditorState.

struct EditorStateFocusedKey: FocusedValueKey {
    typealias Value = EditorState
}

extension FocusedValues {
    var editorState: EditorState? {
        get { self[EditorStateFocusedKey.self] }
        set { self[EditorStateFocusedKey.self] = newValue }
    }
}

// MARK: - FormatCommands
// Keyboard-first formatting and version commands. The formatting actions write
// Markdown markers into the text; the highlighter renders them live.

struct FormatCommands: Commands {
    @FocusedValue(\.editorState) private var state

    var body: some Commands {
        CommandMenu("Format") {
            Button("Gras") { state?.bold() }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(state == nil)
            Button("Italique") { state?.italic() }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(state == nil)
            Button("Souligné") { state?.underline() }
                .keyboardShortcut("u", modifiers: .command)
                .disabled(state == nil)
            Button("Barré") { state?.strikethrough() }
                .keyboardShortcut("x", modifiers: [.command, .shift])
                .disabled(state == nil)
            Divider()
            Button("Titre 1") { state?.heading(1) }
                .keyboardShortcut("1", modifiers: [.command, .option])
                .disabled(state == nil)
            Button("Titre 2") { state?.heading(2) }
                .keyboardShortcut("2", modifiers: [.command, .option])
                .disabled(state == nil)
            Button("Titre 3") { state?.heading(3) }
                .keyboardShortcut("3", modifiers: [.command, .option])
                .disabled(state == nil)
            Button("Corps de texte") { state?.bodyStyle() }
                .keyboardShortcut("0", modifiers: [.command, .option])
                .disabled(state == nil)
            Divider()
            Button("Insérer un lien…") { state?.requestLink?() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(state == nil)
            Button("Mode écriture") { state?.toggleWritingMode() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(state == nil)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Enregistrer une version") { state?.requestSaveVersion?() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(state == nil)
            Button("Historique des versions…") { state?.requestHistory?() }
                .disabled(state == nil)
            Divider()
            Button("Exporter…") { state?.requestExport?() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(state == nil)
        }
    }
}
