import SwiftUI
import AppKit

// MARK: - AppSettings

@Observable final class AppSettings {
    static let shared = AppSettings()
    private static let ud = UserDefaults.standard

    // Persisted typography
    var fontName:         String = "Georgia"
    var fontSize:         Double = 18
    var lineSpacing:      Double = 6
    var paragraphSpacing: Double = 12
    var horizontalInset:  Double = 80

    // Single writing mode: hides sidebar + enables typewriter centering + paragraph dimming
    var writingMode: Bool = false

    // MARK: Available fonts

    static let availableFonts: [(name: String, label: String)] = [
        ("Georgia",             "Georgia"),
        ("Palatino-Roman",      "Palatino"),
        ("Baskerville",         "Baskerville"),
        ("HoeflerText-Regular", "Hoefler Text"),
        ("HelveticaNeue",       "Helvetica Neue"),
    ]

    // MARK: Resolved editor types

    func editorFont(size: Double? = nil) -> NSFont {
        let s = size ?? fontSize
        return NSFont(name: fontName, size: s)
            ?? NSFont(name: "Georgia", size: s)
            ?? .systemFont(ofSize: s)
    }

    var editorParagraphStyle: NSParagraphStyle {
        let ps = NSMutableParagraphStyle()
        ps.lineSpacing      = lineSpacing
        ps.paragraphSpacing = paragraphSpacing
        return ps
    }

    /// The baseline attributes for body text — single source of truth for every
    /// typing-attribute reset and new-content path.
    var defaultEditorAttributes: [NSAttributedString.Key: Any] {
        [
            .font:            editorFont(),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle:  editorParagraphStyle
        ]
    }

    // MARK: Persistence

    private init() {
        let ud = AppSettings.ud
        if let v = ud.string(forKey: "as.fontName")                             { fontName         = v }
        if let v = ud.object(forKey: "as.fontSize")          as? Double, v > 0  { fontSize         = v }
        if let v = ud.object(forKey: "as.lineSpacing")        as? Double        { lineSpacing       = v }
        if let v = ud.object(forKey: "as.paragraphSpacing")   as? Double        { paragraphSpacing  = v }
        if let v = ud.object(forKey: "as.horizontalInset")    as? Double, v > 0 { horizontalInset   = v }
        writingMode = ud.bool(forKey: "as.writingMode")
    }

    func save() {
        let ud = AppSettings.ud
        ud.set(fontName,         forKey: "as.fontName")
        ud.set(fontSize,         forKey: "as.fontSize")
        ud.set(lineSpacing,      forKey: "as.lineSpacing")
        ud.set(paragraphSpacing, forKey: "as.paragraphSpacing")
        ud.set(horizontalInset,  forKey: "as.horizontalInset")
        ud.set(writingMode,      forKey: "as.writingMode")
    }
}
