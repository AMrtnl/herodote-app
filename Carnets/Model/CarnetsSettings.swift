import Foundation
import Observation
import UIKit

// MARK: - Tool configuration (persisted)

nonisolated enum PenStyle: String, Codable, CaseIterable, Identifiable, Sendable {
    case fountain, ballpoint, felt, brush

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fountain:  return "Plume"
        case .ballpoint: return "Bille"
        case .felt:      return "Feutre fin"
        case .brush:     return "Pinceau"
        }
    }

    var symbol: String {
        switch self {
        case .fountain:  return "pencil.tip"
        case .ballpoint: return "pencil"
        case .felt:      return "pencil.line"
        case .brush:     return "paintbrush.pointed"
        }
    }
}

nonisolated enum EraserMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case stroke, precise

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stroke:  return "Trait entier"
        case .precise: return "Précise"
        }
    }
}

nonisolated struct ToolSettings: Codable, Equatable, Sendable {
    var penStyle: PenStyle = .fountain
    var penColor: String = "#1C1C1E"
    var penWidth: Int = 1
    var pencilColor: String = "#3A3A3C"
    var pencilWidth: Int = 1
    var highlighterColor: String = "#FFE14D"
    var highlighterWidth: Int = 1
    var eraserMode: EraserMode = .stroke
    var eraserWidth: Int = 1
    /// Most recent custom colours, newest first.
    var customColors: [String] = []
}

// MARK: - Library sorting

nonisolated enum LibrarySort: String, Codable, CaseIterable, Identifiable, Sendable {
    case modified, opened, title, created

    var id: String { rawValue }

    var label: String {
        switch self {
        case .modified: return "Date de modification"
        case .opened:   return "Dernière ouverture"
        case .title:    return "Titre"
        case .created:  return "Date de création"
        }
    }
}

// MARK: - Recognition languages offered in Settings

nonisolated struct RecognitionLanguage: Identifiable, Hashable, Sendable {
    let code: String
    let label: String
    var id: String { code }

    static let all: [RecognitionLanguage] = [
        RecognitionLanguage(code: "fr", label: "Français"),
        RecognitionLanguage(code: "en", label: "English"),
        RecognitionLanguage(code: "de", label: "Deutsch"),
        RecognitionLanguage(code: "es", label: "Español"),
        RecognitionLanguage(code: "it", label: "Italiano"),
        RecognitionLanguage(code: "pt", label: "Português"),
    ]
}

// MARK: - Page scrolling

enum ScrollDirection: String, CaseIterable, Identifiable {
    /// Pages one below the other, scrolled continuously.
    case vertical
    /// Pages side by side, turned one at a time.
    case horizontal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical:   return "Verticale (continue)"
        case .horizontal: return "Horizontale (page à page)"
        }
    }
}

// MARK: - CarnetsSettings

@Observable final class CarnetsSettings {
    static let shared = CarnetsSettings()

    /// Draw with a finger as well as Apple Pencil.
    var fingerDrawing: Bool
    /// Hold the pen still at the end of a stroke to turn it into a perfect shape.
    var holdToSnapShapes: Bool
    /// Two-finger tap = undo, three-finger tap = redo.
    var tapGesturesForUndo: Bool
    /// Ordered recognition language codes.
    var recognitionLanguages: [String]
    var defaultTemplate: PageTemplate
    var defaultPaper: PaperStyle
    var defaultFormat: PageFormat
    var librarySort: LibrarySort
    var scrollDirection: ScrollDirection
    var tools: ToolSettings

    private let defaults = UserDefaults.standard

    private init() {
        let d = UserDefaults.standard
        fingerDrawing = (d.object(forKey: Keys.fingerDrawing) as? Bool) ?? !UIPencilInteraction.prefersPencilOnlyDrawing
        holdToSnapShapes = (d.object(forKey: Keys.holdToSnap) as? Bool) ?? true
        tapGesturesForUndo = (d.object(forKey: Keys.tapUndo) as? Bool) ?? true
        recognitionLanguages = d.stringArray(forKey: Keys.languages) ?? CarnetsSettings.systemLanguageDefaults()
        defaultTemplate = d.string(forKey: Keys.template).flatMap(PageTemplate.init(rawValue:)) ?? .lined
        defaultPaper = d.string(forKey: Keys.paper).flatMap(PaperStyle.init(rawValue:)) ?? .white
        defaultFormat = d.string(forKey: Keys.format).flatMap(PageFormat.init(rawValue:)) ?? .a4
        librarySort = d.string(forKey: Keys.sort).flatMap(LibrarySort.init(rawValue:)) ?? .modified
        scrollDirection = d.string(forKey: Keys.scroll).flatMap(ScrollDirection.init(rawValue:)) ?? .vertical
        if let data = d.data(forKey: Keys.tools),
           let decoded = try? JSONDecoder().decode(ToolSettings.self, from: data) {
            tools = decoded
        } else {
            tools = ToolSettings()
        }
    }

    func save() {
        defaults.set(fingerDrawing, forKey: Keys.fingerDrawing)
        defaults.set(holdToSnapShapes, forKey: Keys.holdToSnap)
        defaults.set(tapGesturesForUndo, forKey: Keys.tapUndo)
        defaults.set(recognitionLanguages, forKey: Keys.languages)
        defaults.set(defaultTemplate.rawValue, forKey: Keys.template)
        defaults.set(defaultPaper.rawValue, forKey: Keys.paper)
        defaults.set(defaultFormat.rawValue, forKey: Keys.format)
        defaults.set(librarySort.rawValue, forKey: Keys.sort)
        defaults.set(scrollDirection.rawValue, forKey: Keys.scroll)
        if let data = try? JSONEncoder().encode(tools) {
            defaults.set(data, forKey: Keys.tools)
        }
    }

    /// French first when the device speaks French, English always included.
    private static func systemLanguageDefaults() -> [String] {
        let preferred = Locale.preferredLanguages.compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        var result: [String] = []
        for code in preferred where RecognitionLanguage.all.contains(where: { $0.code == code }) && !result.contains(code) {
            result.append(code)
        }
        if !result.contains("fr") { result.append("fr") }
        if !result.contains("en") { result.append("en") }
        return result
    }

    private enum Keys {
        static let fingerDrawing = "carnets.fingerDrawing"
        static let holdToSnap = "carnets.holdToSnap"
        static let tapUndo = "carnets.tapUndo"
        static let languages = "carnets.languages"
        static let template = "carnets.defaultTemplate"
        static let paper = "carnets.defaultPaper"
        static let format = "carnets.defaultFormat"
        static let sort = "carnets.librarySort"
        static let scroll = "carnets.scrollDirection"
        static let tools = "carnets.tools"
    }
}
