# Hérodote

This Xcode project (`Untitled Project.xcodeproj`) contains two apps:

| Target | Platform | What it is |
|---|---|---|
| **MyApp** (Hérodote) | macOS | The typed-writing app: groups, sheets, rich text, links, annotations, Élan stats. |
| **Carnets** | iPadOS / iOS (runs on Apple-silicon Macs as "Designed for iPad") | A handwritten-notebook app in the spirit of reMarkable and GoodNotes. |

## Carnets: handwritten notebooks

Choose the **Carnets** scheme, pick an iPad (a real device with an Apple Pencil gives the best experience), and run. It needs Xcode 27 / iOS 27, the same SDK as the rest of the project.

### Features

**Library**
- Notebooks with fabric-style covers, or a preview of the first page
- Folders, favourites, recents, sorting, drag-and-drop into folders
- Import a PDF to annotate it, import photos, or scan paper documents with the camera (VisionKit)
- "Open in Carnets" from the Files app or the share sheet for PDFs
- Search across notebook titles, **handwriting**, PDF text and text boxes, with highlighted snippets

**Writing**
- PencilKit ink with low latency, pressure and tilt: fountain pen, ballpoint, fine felt, brush, pencil, highlighter
- Stroke eraser or precise eraser (3 sizes), lasso (move / copy / delete), ruler
- **Shape snapping**: hold the tip still at the end of a stroke (or turn on Formes automatiques) to get a perfect line, circle, ellipse, triangle, rectangle or polygon
- Apple Pencil double-tap and squeeze follow the system setting (switch to eraser, previous tool, palette)
- Palm rejection (Pencil-only mode), or finger drawing
- Two-finger tap = undo, three-finger tap = redo; ⌘Z / ⇧⌘Z with a keyboard
- Text boxes (4 font styles, size, colour) and photos placed on the page: move, resize, duplicate, bring to front
- Paper templates: blank, lined, narrow lined, **Seyès**, 5 mm grid, 1 cm grid, dot grid, Cornell, checklist, music staff
- Paper colours: white, ivory, "digital ink" grey, yellow, slate, night. Formats: A4, A5, Letter, 3:4 tablet, square, portrait or landscape
- Pages scroll continuously and zoom from 50 % to 600 %; page backgrounds and PDFs re-render sharply at any zoom
- **Mode papier**: a distraction-free, full-screen mode in the spirit of reMarkable

**Pages**
- Thumbnail navigator: jump, drag to reorder, insert before or after, duplicate, delete, bookmarks
- Change the template or paper of one page or of all pages
- Add pages from a PDF or from scans in the middle of a notebook

**Handwriting → text** (on-device, `PKStrokeRecognizer`, iOS 27)
- Lasso some handwriting, then **Convertir en texte**: edit the result, copy it, share it, or replace the ink with a text box
- Copy all the handwriting of a page as text
- Every page is indexed in the background for library search. Languages are set in Réglages (French and English by default)
- Search inside a notebook highlights the matching words on the page

**Export**
- The whole notebook or a single page as PDF (paper and PDF backgrounds stay vector; ink is embedded at 216 dpi), or a page as a PNG image, through the share sheet

### Architecture

```
Carnets/
  CarnetsApp.swift            App entry, scene-phase flushing
  Model/
    Notebook.swift            Notebook, NotebookPage, PageElement, templates, paper, formats, covers
    NotebookStore.swift       @Observable library: CRUD, folders, import, debounced JSON saves
    NotebookFiles.swift       On-disk layout, drawing I/O, PDF/image importers
    CarnetsSettings.swift     Preferences and tool settings (UserDefaults)
  Rendering/
    PageRenderer.swift        Thread-safe drawing of paper, templates, PDF pages, elements, ink; PDF export
    Thumbnails.swift          Async thumbnail cache + SwiftUI view
    HandwritingIndexer.swift  Background handwriting recognition + library search
  Editor/
    NotebookCanvasController  UIKit core: one PKCanvasView for the whole notebook
    CanvasViews.swift         Page backgrounds (base + zoomed detail tiles), element views, selection
    ShapeRecognizer.swift     Line / ellipse / polygon / rectangle fitting for shape snapping
    EditorModel.swift         Observable editor state shared by SwiftUI and UIKit
    NotebookEditorView.swift  SwiftUI shell: toolbar, menus, search, sheets
    ToolPaletteView.swift     Floating Liquid Glass tool palette + tool options
    PageNavigatorView.swift   Page thumbnails grid
  Library/                    Library grid, covers, new-notebook sheet, search results, settings
  Support/                    Template pickers, text / conversion sheets, share sheet, document scanner
```

**Storage.** Each notebook is a folder in `Application Support/Carnets/Notebooks/<id>/`:
- `notebook.json` holds the metadata and pages
- `drawings/<page>.drawing` holds one PKDrawing per page, in page coordinates
- `assets/` holds imported PDFs, scans and placed photos

Ink is composed into a single canvas while editing, then split back per page when saved (debounced). Only pages that changed are written.
