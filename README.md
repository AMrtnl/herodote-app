# Hérodote

This Xcode project (`Untitled Project.xcodeproj`) contains two apps:

| Target | Platform | What it is |
|---|---|---|
| **MyApp** (Hérodote) | macOS | The typed-writing app: groups, sheets, rich text, links, annotations, Élan stats. |
| **Carnets** | iPadOS / iOS (runs on Apple-silicon Macs as "Designed for iPad") | Three apps in one: handwritten notebooks (GoodNotes-style), Obsidian-style notes and Ulysses-style writing projects. |

## Carnets: GoodNotes + Obsidian + Ulysses in one app

Carnets is three apps in one. Each has its own tab (⌘1, ⌘2, ⌘3), its own sidebar and its own navigation, and all three store their files in **one Obsidian-compatible vault** that you can host on your own server:

| Tab | Inspired by | What you get |
|---|---|---|
| **Carnets** | GoodNotes / reMarkable | The handwritten-notebook app: library with covers and folders, Apple Pencil handwriting, paper templates, PDF annotation, shape snapping, laser pointer, page-by-page or continuous scrolling, page outline, on-device handwriting recognition, GoodNotes import (details below) |
| **Notes** | Obsidian | Markdown notes with `[[wikilinks]]`, backlinks, #tags, front matter, a graph view, daily notes, a quick switcher, and links that update everywhere when you rename a note |
| **Écriture** | Ulysses | Writing projects made of ordered sheets, word goals per project and per sheet, a deadline, a focus/typewriter writing mode, Élan writing stats, and assembling a whole project to PDF, Markdown or HTML |

Choose the **Carnets** scheme, pick an iPad (a real device with an Apple Pencil gives the best experience), and run. It needs Xcode 27 / iOS 27, the same SDK as the rest of the project.

### Write on iPad, read everywhere

Handwritten notebooks are **created and edited on iPad only**. On **iPhone** and on **Mac** ("Designed for iPad") they open **read-only**: the library, pages, zoom, page-by-page mode, page grid, outline, bookmarks, search in the handwriting, the laser pointer, copying the handwriting as text and PDF/image export all work, but nothing is ever written to the notebook. The iPad stays the only device that changes a notebook, so syncing never has to merge two versions of the same ink. Notebooks reach the other devices through the vault (your WebDAV server or a synced folder), and every notebook also exists as a Markdown note with its pages as images, readable in Obsidian on any platform. Notes and Écriture stay fully editable everywhere.

To try the reader on an iPad simulator, add the launch argument `-carnets.readOnly YES` to the scheme.

### The vault (your files, your server)

The vault is a plain folder:

```
Coffre/
  .obsidian/                 minimal Obsidian config (created only if missing)
  Bienvenue.md               your notes and folders
  Journal/2026-11-01.md      daily notes
  Écriture/<Project>/        sheets (.md) + projet.json (order, goals, deadline)
  Carnets/<Notebook>.md      one note per handwritten notebook: page images, recognised text,
                             and a carnets:// link that reopens it in Carnets
  Carnets/Données/<uuid>/    notebook data (ink, PDFs, page renders), hidden from Obsidian
  Pièces jointes/            attachments
  .trash/                    deleted notes (Obsidian convention)
```

- **On the device** by default: the vault appears in the Files app (On My iPad › Carnets › Coffre).
- **Any folder**: pick an iCloud Drive, Nextcloud, Synology Drive, Working Copy (Git) or Möbius Sync (Syncthing) folder in Réglages › Coffre et serveur.
- **Your own server (WebDAV)**: Nextcloud, ownCloud, Synology, QNAP, Apache/nginx WebDAV, `rclone serve webdav`… Two-way sync runs automatically after changes and when the app becomes active. When a file changed on both sides, both versions are kept (`… (conflit serveur <date>).md`). The password is stored in the Keychain.
- **Obsidian**: open the same folder as a vault. Handwritten notebooks show up as notes with their pages as images and their handwriting as searchable text.

Existing handwritten notebooks are moved into the vault automatically the first time the new version runs.

### Coming from GoodNotes (keep both)

Your GoodNotes notebooks can live in Carnets alongside native ones, and you can keep using GoodNotes:

- **Import**: in GoodNotes, choose Share › Export › **PDF**; a folder exports as a ZIP. In Carnets, open "Importer depuis GoodNotes…" and pick PDFs, ZIP archives or whole folders. GoodNotes folders are recreated (nested folders appear as "Cours › Philosophie"), and PDFs exported by GoodNotes are detected from their metadata.
- **Searchable handwriting**: GoodNotes flattens handwriting into the PDF, so Carnets reads it with on-device text recognition (Vision). It can then be found in search, and it appears in the notebook's note in the vault.
- **Update in place**: keep writing in GoodNotes, export again, and import with "Mettre à jour" (or use Infos › "Mettre à jour depuis un export plus récent…"). Each page is matched with its new version by its page number in the PDF, so the ink, text boxes, photos, titles and bookmarks you added in Carnets stay on the right page, pages you added in Carnets stay where they are, and pages added in GoodNotes are inserted in place. Same-named notebooks in different folders are told apart.
- **Back to GoodNotes**: Infos › "Envoyer vers GoodNotes (PDF)" exports the notebook with all its writing, including what you added in Carnets, under the notebook's name. Carnets remembers what it printed into that PDF: when the GoodNotes export of it comes back, your Carnets ink is not shown twice. "Partager le PDF d'origine" returns the original export under its original name.
- **Manage many notebooks**: a "Importés de GoodNotes" section, a GoodNotes badge on covers, and multi-selection to move, favourite, **merge** (in display order, originals kept), export or delete several notebooks at once.
- `.goodnotes` files use GoodNotes' own format, which can't be read reliably; the import explains how to export them as PDF instead.

### Handwriting features (Carnets manuscrits)

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
- Pages scroll continuously, or **side by side, one page at a time** (swipe to turn the page), and zoom from 50 % to 600 %; page backgrounds and PDFs re-render sharply at any zoom
- **Laser pointer**: point at the page during a presentation or a call; the glowing red trail fades by itself and is never saved (also on iPhone and Mac)
- **Mode papier**: a distraction-free, full-screen mode in the spirit of reMarkable

**Pages**
- Thumbnail navigator: jump, drag to reorder, insert before or after, duplicate, delete, bookmarks
- **Outline (« Plan »)**: name pages to build the notebook's table of contents; titles show in the page indicator and become headings in the notebook's vault note
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
  CarnetsApp.swift            App entry: environment, sync on activation
  App/
    AppRouter.swift           Spaces (tabs), per-space sections and navigation, carnets:// URLs, reading positions
    RootView.swift            TabView Carnets / Notes / Écriture, quick switcher, sync status
    Sidebars.swift            One sidebar per space; read-only banner
    Platform.swift            Where notebooks can be edited (iPad) and where they are read-only
  Vault/
    VaultModel.swift          Vault layout, notes, Markdown parsing (links, tags, front matter), scanner
    VaultStore.swift          Index, backlinks, link-updating rename, trash, daily notes, writing projects
    NotebookVaultBridge.swift Companion Markdown note + page images for every notebook
    WebDAVSync.swift          WebDAV client, two-way sync engine, Keychain, SyncCenter
  Notes/
    MarkdownTextView.swift    Live Markdown styling, link taps, checkboxes, format bar, typewriter/focus
    NoteEditorView.swift      Note screen, [[ autocomplete, inspector (backlinks, outline, stats, goal)
    NotesBrowserView.swift    Folders and notes, tags, unified search
    GraphView.swift           Force-directed graph of linked notes and notebooks
  Writing/
    WritingViews.swift        Projects, Élan stats, ordered sheets, goals and deadline
    MarkdownExporter.swift    Markdown → PDF / HTML export (notes and assembled projects)
  Model/
    Notebook.swift            Notebook, NotebookPage, PageElement, templates, paper, formats, covers
    NotebookStore.swift       @Observable library: CRUD, folders, import, debounced JSON saves
    NotebookFiles.swift       On-disk layout, drawing I/O, PDF/image importers
    NotebookRoundTrip.swift   Page matching for newer exports; GoodNotes round trips without doubled ink
    GoodNotesImport.swift     ZIP reader, GoodNotes export detection, import candidates
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

**Notebook storage.** Each notebook is a folder in `<vault>/Carnets/Données/<id>/`:
- `notebook.json` holds the metadata and pages
- `drawings/<page>.drawing` holds one PKDrawing per page, in page coordinates
- `assets/` holds imported PDFs, scans and placed photos

Ink is composed into a single canvas while editing, then split back per page when saved (debounced). Only pages that changed are written.
