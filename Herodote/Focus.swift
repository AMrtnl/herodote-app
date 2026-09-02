import SwiftUI

// MARK: - FocusedValue for EditorState
// Lets menu commands (Phase 2) reach the active editor's EditorState.

struct EditorStateFocusedKey: FocusedValueKey {
    typealias Value = EditorState
}

extension FocusedValues {
    var editorState: EditorState? {
        get { self[EditorStateFocusedKey.self] }
        set { self[EditorStateFocusedKey.self] = newValue }
    }
}
