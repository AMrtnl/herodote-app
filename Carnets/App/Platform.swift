import UIKit

// MARK: - Platform
// Handwritten notebooks are written on iPad. On iPhone and on Mac they open read-only:
// pages, zoom, page grid, outline, search, laser pointer and export all work, but nothing
// is written — the iPad stays the only device that changes a notebook, so syncing through
// the vault never has to reconcile two versions of the same ink.

enum Platform {
    static let isMac = ProcessInfo.processInfo.isiOSAppOnMac || ProcessInfo.processInfo.isMacCatalystApp
    static let isPhone = UIDevice.current.userInterfaceIdiom == .phone

    /// `-carnets.readOnly YES` (launch argument) previews the reader on an iPad.
    static let canEditNotebooks = UIDevice.current.userInterfaceIdiom == .pad && !isMac
        && !UserDefaults.standard.bool(forKey: "carnets.readOnly")

    static var deviceName: String {
        if isMac { return "Mac" }
        return isPhone ? "iPhone" : "iPad"
    }

    static var readOnlyTitle: String { "Lecture seule sur \(deviceName)" }

    static var readOnlyExplanation: String {
        "Créez et modifiez vos carnets sur iPad. Ils arrivent ici par le coffre (serveur ou dossier synchronisé) : feuilletez, cherchez, exportez."
    }
}
