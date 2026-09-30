import CoreFoundation
import Foundation
import Observation

/// Which of Panely's localizations the UI is in *right now*.
///
/// macOS fixes an app's localization at launch, so switching languages from
/// Settings would normally mean a restart. Panely instead looks its own
/// strings up in the chosen `.lproj` explicitly — `String(localized:bundle:
/// .localized)` in code, the `\.locale` environment for SwiftUI text — and
/// both follow this object, so the UI changes the moment a language is
/// picked. Only AppKit's own items (Edit/Window menus, Quit, standard panel
/// buttons) stay in the launch language until the next start.
///
/// Observable so any SwiftUI body or menu that reads `bundle` / `locale`
/// re-renders on a switch. Lock-protected because strings are also looked
/// up off the main actor (archive errors, load messages).
@Observable
nonisolated final class AppLocalization: @unchecked Sendable {
    static let shared = AppLocalization()

    /// Localizations Panely ships, by language code.
    static let supportedLanguages = ["en", "ko"]
    /// Shown when the system language isn't one Panely supports.
    static let fallbackLanguage = "en"

    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var current: (language: String, bundle: Bundle)

    init(language: String = AppLocalization.resolve(.system)) {
        current = (language, Self.bundle(for: language))
    }

    /// Language code in effect ("en" / "ko").
    var language: String {
        access(keyPath: \.language)
        return lock.withLock { current.language }
    }

    /// Bundle to look Panely's strings up in.
    var bundle: Bundle {
        access(keyPath: \.language)
        return lock.withLock { current.bundle }
    }

    var locale: Locale { Locale(identifier: language) }

    /// Switch to `selection`, resolving "System Default" against the Mac's
    /// current language list.
    func apply(_ selection: AppLanguage, systemLanguages: [String] = AppLocalization.systemPreferredLanguages()) {
        let language = Self.resolve(selection, systemLanguages: systemLanguages)
        guard language != lock.withLock({ current.language }) else { return }
        withMutation(keyPath: \.language) {
            lock.withLock { current = (language, Self.bundle(for: language)) }
        }
    }

    // MARK: - Resolution

    /// The language `selection` means today. "System Default" takes the
    /// Mac's *primary* language when Panely supports it and English
    /// otherwise — a Japanese system shows English, not whichever supported
    /// language happens to sit lower in its list.
    static func resolve(
        _ selection: AppLanguage,
        systemLanguages: [String] = AppLocalization.systemPreferredLanguages()
    ) -> String {
        switch selection {
        case .english: "en"
        case .korean: "ko"
        case .system: supportedLanguage(for: systemLanguages.first) ?? fallbackLanguage
        }
    }

    /// `ko-KR` → `ko`; `nil` for a language Panely doesn't ship.
    static func supportedLanguage(for identifier: String?) -> String? {
        guard let identifier else { return nil }
        let code = Locale(identifier: identifier).language.languageCode?.identifier ?? identifier
        return supportedLanguages.contains(code) ? code : nil
    }

    /// What to store as Panely's own `AppleLanguages`, which is what AppKit
    /// reads at launch for the parts Panely doesn't draw itself. An explicit
    /// choice is written through; "System Default" normally clears it so
    /// macOS decides — except when the primary language is unsupported,
    /// where macOS would pick the next supported one down the list and the
    /// system menus would disagree with Panely's English.
    static func appleLanguagesOverride(for selection: AppLanguage, systemLanguages: [String]) -> [String]? {
        switch selection {
        case .english, .korean:
            [selection.rawValue]
        case .system:
            supportedLanguage(for: systemLanguages.first) == nil ? [fallbackLanguage] : nil
        }
    }

    /// The Mac's language list, not Panely's own override: an explicit
    /// `-AppleLanguages` launch argument (Xcode's scheme language, test runs)
    /// wins; otherwise the user's global preference.
    static func systemPreferredLanguages() -> [String] {
        let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        if let languages = arguments["AppleLanguages"] as? [String], !languages.isEmpty {
            return languages
        }
        let global = CFPreferencesCopyValue(
            "AppleLanguages" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? [String]
        return global ?? Locale.preferredLanguages
    }

    private static func bundle(for language: String) -> Bundle {
        Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

extension Bundle {
    /// Where Panely's strings are looked up: the language chosen in Settings,
    /// not the one the process launched with. Pass it to every
    /// `String(localized:)` so the text follows a live language switch.
    nonisolated static var localized: Bundle { AppLocalization.shared.bundle }
}
