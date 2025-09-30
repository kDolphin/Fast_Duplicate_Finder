import Foundation
import SwiftUI
import Combine

/// Loads Localizable.strings following **system language** (System Settings → Language & Region).
/// No in-app language override — change language in macOS System Settings.
class LocalizationManager: ObservableObject {
    static let shared = LocalizationManager()
    
    /// Display code for diagnostics: "zh" or "en"
    @Published private(set) var currentLanguage: String = "en"
    
    private var localizedStrings: [String: String] = [:]
    private var localeObserver: NSObjectProtocol?
    
    init() {
        reloadFromSystem()
        // Prefer AppleLanguages change; also re-read when app becomes active
        localeObserver = NotificationCenter.default.addObserver(
            forName: NSLocale.currentLocaleDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reloadFromSystem()
        }
    }
    
    deinit {
        if let localeObserver {
            NotificationCenter.default.removeObserver(localeObserver)
        }
    }
    
    /// Call on appear / activation if system language may have changed while running.
    func reloadFromSystem() {
        let code = Self.systemLanguageCode()
        currentLanguage = code
        // Clear stale manual override so Bundle / OS also stay consistent
        UserDefaults.standard.removeObject(forKey: "app_language")
        loadStrings()
        objectWillChange.send()
    }
    
    /// Prefer preferredLanguages (user’s ordered list from System Settings).
    static func systemLanguageCode() -> String {
        let preferred = Locale.preferredLanguages.first ?? "en"
        if preferred.hasPrefix("zh") { return "zh" }
        return "en"
    }
    
    private func loadStrings() {
        let localization = currentLanguage.hasPrefix("zh") ? "zh-Hans" : "en"
        
        if let dict = loadStringsDict(localization: localization) {
            localizedStrings = dict
            return
        }
        
        #if DEBUG
        print("Failed to load localization: \(localization)")
        #endif
        if localization != "en" {
            if let dict = loadStringsDict(localization: "en") {
                localizedStrings = dict
            }
        }
    }
    
    private func loadStringsDict(localization: String) -> [String: String]? {
        if let url = Bundle.main.url(
            forResource: "Localizable",
            withExtension: "strings",
            subdirectory: nil,
            localization: localization
        ), let dict = NSDictionary(contentsOf: url) as? [String: String] {
            return dict
        }
        if let path = Bundle.main.path(
            forResource: "Localizable",
            ofType: "strings",
            inDirectory: "\(localization).lproj"
        ), let dict = NSDictionary(contentsOfFile: path) as? [String: String] {
            return dict
        }
        return nil
    }
    
    func localizedString(_ key: String) -> String {
        localizedStrings[key] ?? key
    }
}

extension String {
    var localized: String {
        LocalizationManager.shared.localizedString(self)
    }
    
    func localized(_ arguments: CVarArg...) -> String {
        let format = LocalizationManager.shared.localizedString(self)
        return String(format: format, arguments: arguments)
    }
}

extension Notification.Name {
    /// Open the app Settings window (⌘,)
    static let openAppSettings = Notification.Name("finddup.openAppSettings")
}
