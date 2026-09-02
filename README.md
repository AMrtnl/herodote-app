# Hérodote

A Ulysses-style **macOS** writing app. The UI tagline is *L'écriture invisible*.

The product name in the app is **Hérodote**. The Xcode project, target, and source folder use the ASCII name **Herodote**.

## Requirements

- macOS (the editor is AppKit `NSTextView` wrapped in SwiftUI)
- [Xcode](https://developer.apple.com/xcode/) — this project was created with Xcode 26 and sets `MACOSX_DEPLOYMENT_TARGET` to 26.5.1

Choose a **Mac** destination when building. The `.xcodeproj` still lists other Apple platforms from the original template; the current sources are not an iOS/iPadOS app.

## Build in Xcode

1. Clone this repository.
2. Open `Herodote.xcodeproj` in Xcode (File → Open, or double-click the project).
3. Select the **Herodote** scheme and a Mac run destination.
4. Build and run with **Product → Run** (`⌘R`).

Signing uses Automatic with the team already set on the target. Change the development team in the target’s Signing & Capabilities tab if Xcode asks you to.

There is no command-line or Swift Package Manager build; Xcode is the intended workflow.

## What the app does

These are features present in the current sources, not a roadmap.

**Library**

- Three-column window: hierarchical group tree, sheet list, editor
- Nested groups with rename, delete, custom folder icons and colors
- Sheets (rich-text pages) you can add, rename, reorder, and delete
- Command-N creates a new group

**Editor**

- Rich text with a selection format bar: bold, italic, underline, heading 1/2, body style
- Cross-sheet links (`⌘K`) using `herodote://` URLs; clicking a link opens the target sheet
- Inline annotations (comments) on selected text
- Writing mode (`⌘⇧F`): hides the split-view columns, typewriter-style vertical centering, and dims all but the current paragraph
- Live word count in the toolbar

**Inspector** (right sidebar)

- Word / character / paragraph counts and estimated reading time
- Optional word-count goal with progress
- Keywords, author notes, incoming/outgoing sheet links, and annotations

**Élan** (writing dashboard)

- All-time words, words today, current streak, and active days
- 26-week activity heatmap
- Per-group word totals

**Settings** (`⌘,`)

- Font (Georgia, Palatino, Baskerville, Hoefler Text, Helvetica Neue), size, line spacing, paragraph spacing, and horizontal margins

## Data

Groups are saved as JSON files with a `.herodote` extension under Application Support (`~/Library/Application Support/Hérodote/`). Daily word counts go in `activity.json` in the same folder. Typography and writing-mode preferences use `UserDefaults`.

The Info.plist also declares a `com.herodote.project` document type; the running app loads and saves through `LibraryManager`, not `NSDocument`.
