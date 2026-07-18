import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ExportFormat

enum ExportFormat: String, CaseIterable, Identifiable {
    case pdf      = "PDF"
    case docx     = "Word (DOCX)"
    case markdown = "Markdown"
    case html     = "HTML"
    case rtf      = "RTF"

    var id: String { rawValue }

    var fileExtension: String {
        switch self {
        case .pdf:      return "pdf"
        case .docx:     return "docx"
        case .markdown: return "md"
        case .html:     return "html"
        case .rtf:      return "rtf"
        }
    }
}

// MARK: - ExportEngine
// One source, many outputs (Ulysses principle). Material sheets are always excluded.

enum ExportEngine {
    enum ExportError: Error { case generationFailed, nothingToExport }

    static func export(sheets: [WritingSheet], title: String, format: ExportFormat, to url: URL) throws {
        // Material sheets are excluded from group exports; an explicitly
        // exported single sheet is always honored, material or not.
        let exportSheets = sheets.count == 1 ? sheets : sheets.filter { !$0.isMaterial }
        guard !exportSheets.isEmpty else { throw ExportError.nothingToExport }
        let includeTitles = exportSheets.count > 1
        switch format {
        case .markdown:
            // The text already is Markdown — join the raw sources
            let md = exportSheets
                .map { (includeTitles ? "# \($0.title)\n\n" : "") + $0.plainText }
                .joined(separator: "\n\n")
            try Data(md.utf8).write(to: url, options: .atomic)
        case .html, .rtf, .docx:
            let content = combined(exportSheets, includeTitles: includeTitles)
            let type: NSAttributedString.DocumentType =
                format == .html ? .html : (format == .rtf ? .rtf : .officeOpenXML)
            let data = try content.data(
                from: NSRange(location: 0, length: content.length),
                documentAttributes: [.documentType: type]
            )
            try data.write(to: url, options: .atomic)
        case .pdf:
            try writePDF(combined(exportSheets, includeTitles: includeTitles), to: url)
        }
    }

    /// Concatenate sheets, render the markdown styling, then strip the marker
    /// characters so the output carries formatting without syntax.
    private static func combined(_ sheets: [WritingSheet], includeTitles: Bool) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let settings = AppSettings.shared
        let titleBase = settings.editorFont(size: settings.fontSize + 12)
        let titleDescriptor = titleBase.fontDescriptor
            .withSymbolicTraits(titleBase.fontDescriptor.symbolicTraits.union(.bold))
        let titleFont = NSFont(descriptor: titleDescriptor, size: titleBase.pointSize) ?? titleBase
        for (index, sheet) in sheets.enumerated() {
            if includeTitles {
                out.append(NSAttributedString(string: "\(sheet.title)\n", attributes: [
                    .font: titleFont,
                    .foregroundColor: NSColor.textColor
                ]))
            }
            out.append(cleaned(sheet.attributedString))
            if index < sheets.count - 1 { out.append(NSAttributedString(string: "\n\n")) }
        }
        return out
    }

    static func cleaned(_ source: NSAttributedString) -> NSAttributedString {
        let m = NSMutableAttributedString(attributedString: source)
        MarkdownHighlighter.highlight(m, in: NSRange(location: 0, length: m.length))
        let markers = MarkdownHighlighter.markerRanges(in: m, within: NSRange(location: 0, length: m.length))
        for r in markers.sorted(by: { $0.location > $1.location }) {
            m.deleteCharacters(in: r)
        }
        m.removeAttribute(.herodoteMD, range: NSRange(location: 0, length: m.length))
        return m
    }

    private static func writePDF(_ content: NSAttributedString, to url: URL) throws {
        let printInfo = NSPrintInfo()
        printInfo.paperSize = NSSize(width: 595, height: 842)   // A4 in points
        printInfo.topMargin = 56;  printInfo.bottomMargin = 56
        printInfo.leftMargin = 56; printInfo.rightMargin = 56
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.jobDisposition = .save
        printInfo.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL.rawValue] = url

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let height = printInfo.paperSize.height - printInfo.topMargin - printInfo.bottomMargin
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        textView.textStorage?.setAttributedString(content)
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()

        let operation = NSPrintOperation(view: textView, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        if !operation.run() { throw ExportError.generationFailed }
    }
}

// MARK: - ExportSheet

struct ExportSheet: View {
    let sheets: [WritingSheet]
    let title: String
    var onClose: () -> Void

    @State private var format: ExportFormat = .pdf
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            Text("Exporter « \(title) »")
                .font(.title3.bold())
            Picker("Format", selection: $format) {
                ForEach(ExportFormat.allCases) { format in
                    Text(format.rawValue).tag(format)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if let message = errorMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 12) {
                Button("Annuler", action: onClose)
                    .keyboardShortcut(.cancelAction)
                Button("Exporter") { runExport() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 320)
    }

    private func runExport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = title
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try ExportEngine.export(sheets: sheets, title: title, format: format, to: url)
                onClose()
            } catch ExportEngine.ExportError.nothingToExport {
                errorMessage = "Rien à exporter — les feuilles marquées comme matériel sont exclues."
            } catch {
                errorMessage = "L'export \(format.rawValue) a échoué. Essayez un autre format."
            }
        }
    }
}
