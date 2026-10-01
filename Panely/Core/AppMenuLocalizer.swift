import AppKit
import Observation

/// Keeps AppKit's standard menu titles in the language selected in Settings.
/// Only titles change: targets, actions, validation and shortcuts stay intact.
/// SwiftUI can rebuild the menus when focus or window state changes, so menu
/// notifications reapply the translations after those updates as well.
@MainActor
final class AppMenuLocalizer: NSObject {
    private let localization: AppLocalization
    private let mainMenu: @MainActor () -> NSMenu?
    private var started = false
    private var applying = false
    private var refreshScheduled = false
    private let titleKeys: [String: String]
    private let itemTitles = NSMapTable<NSMenuItem, TitleRecord>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    private final class TitleRecord {
        let key: String
        let title: String

        init(key: String, title: String) {
            self.key = key
            self.title = title
        }
    }

    init(localization: AppLocalization, mainMenu: @escaping @MainActor () -> NSMenu? = { NSApp.mainMenu }) {
        self.localization = localization
        self.mainMenu = mainMenu
        var titleKeys: [String: String] = [:]
        for key in Self.standardKeys.sorted() {
            titleKeys[key] = key
            for language in AppLocalization.supportedLanguages {
                if let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
                   let bundle = Bundle(url: url) {
                    titleKeys[bundle.localizedString(forKey: key, value: key, table: nil)] = key
                }
            }
        }
        self.titleKeys = titleKeys
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        for name in [NSMenu.didAddItemNotification, NSMenu.didChangeItemNotification,
                     NSMenu.didBeginTrackingNotification] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(menuChanged(_:)), name: name, object: nil
            )
        }
        observeLanguage()
        apply()
    }

    func stop() {
        started = false
        NotificationCenter.default.removeObserver(self)
    }

    func apply() {
        guard !applying, let menu = mainMenu() else { return }
        applying = true
        defer { applying = false }
        for item in menu.items {
            guard let submenu = item.submenu else { continue }
            if let key = titleKey(for: item) ?? titleKeys[submenu.title],
               Self.topLevelKeys.contains(key) {
                setTitle(key, on: item)
                translateItems(in: submenu)
            } else if submenu.items.contains(where: { $0.action == #selector(NSApplication.terminate(_:)) })
                        || item.title == "Panely" {
                translateItems(in: submenu)
            }
        }
    }

    private func observeLanguage() {
        withObservationTracking {
            _ = localization.language
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.started else { return }
                self.observeLanguage()
                self.apply()
            }
        }
    }

    @objc private func menuChanged(_ notification: Notification) {
        guard started, !applying, !refreshScheduled,
              let changedMenu = notification.object as? NSMenu,
              let menu = mainMenu() else { return }
        var root = changedMenu
        while let parent = root.supermenu { root = parent }
        guard root === menu else { return }
        refreshScheduled = true
        // Wait for SwiftUI to finish inserting/replacing its menu items.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            if self.started { self.apply() }
        }
    }

    private func translateItems(in menu: NSMenu) {
        for item in menu.items where !item.isSeparatorItem {
            let action = item.action.map(NSStringFromSelector)
            let key = titleKey(for: item) ?? action.flatMap { Self.actionKeys[$0] }
            guard let key, !Self.topLevelKeys.contains(key) else { continue }
            // Undo/redo and full-screen titles reflect current state. Preserve
            // operation names and choose Enter/Exit from the actual title.
            if ["undo:", "redo:", "toggleFullScreen:"].contains(action), titleKeys[item.title] == nil {
                continue
            }
            // A Window menu also holds document names. Those have their own
            // actions and must keep their original titles, even if named Copy.
            if action == "makeKeyAndOrderFront:" || item.target is NSWindow || item.representedObject is NSWindow {
                continue
            }
            setTitle(key, on: item)
            if let submenu = item.submenu, key != "Services" {
                translateItems(in: submenu)
            }
        }
    }

    private func titleKey(for item: NSMenuItem) -> String? {
        // Two system labels can share a translation (Full Screen / Entire
        // Screen). Remember the source key so switching back stays accurate.
        if let record = itemTitles.object(forKey: item), record.title == item.title {
            return record.key
        }
        let key = titleKeys[item.title]
        if key == "Full Screen", item.title != key, item.submenu == nil {
            return "Entire Screen"
        }
        return key
    }

    private func setTitle(_ key: String, on item: NSMenuItem) {
        let title = String(localized: String.LocalizationValue(key), bundle: localization.bundle)
        itemTitles.setObject(TitleRecord(key: key, title: title), forKey: item)
        if item.title != title { item.title = title }
        if let submenu = item.submenu, submenu.title != title { submenu.title = title }
    }

    private static let topLevelKeys: Set<String> = ["File", "Edit", "View", "Window", "Help"]

    private static let actionKeys = [
        "orderFrontStandardAboutPanel:": "About Panely",
        "terminate:": "Quit Panely",
        "hide:": "Hide Panely",
        "hideOtherApplications:": "Hide Others",
        "unhideAllApplications:": "Show All",
        "performClose:": "Close",
        "undo:": "Undo",
        "redo:": "Redo",
        "cut:": "Cut",
        "copy:": "Copy",
        "paste:": "Paste",
        "pasteAsPlainText:": "Paste and Match Style",
        "delete:": "Delete",
        "selectAll:": "Select All",
        "performMiniaturize:": "Minimize",
        "performZoom:": "Zoom",
        "arrangeInFront:": "Bring All to Front",
        "showHelp:": "Panely Help",
        "orderFrontCharacterPalette:": "Emoji & Symbols",
    ]

    private static let standardKeys = topLevelKeys.union(actionKeys.values).union([
        "Services", "Settings…", "Enter Full Screen", "Exit Full Screen",
        "Show Toolbar", "Hide Toolbar", "Customize Toolbar…",
        "Spelling and Grammar", "Show Spelling and Grammar", "Check Document Now",
        "Check Spelling While Typing", "Check Grammar With Spelling", "Correct Spelling Automatically",
        "Substitutions", "Show Substitutions", "Smart Copy/Paste", "Smart Quotes",
        "Smart Dashes", "Smart Links", "Data Detectors", "Text Replacement",
        "Transformations", "Make Upper Case", "Make Lower Case", "Capitalize",
        "Speech", "Start Speaking", "Stop Speaking",
        "Close All", "Minimize All", "Zoom All", "Move & Resize",
        "Fill", "Center", "Left", "Right", "Top", "Bottom",
        "Top Left", "Top Right", "Bottom Left", "Bottom Right",
        "Return to Previous Size", "Arrange", "Fill & Arrange", "Halves", "Quarters",
        "Left & Right", "Right & Left", "Top & Bottom", "Bottom & Top",
        "Left & Quarters", "Right & Quarters", "Top & Quarters", "Bottom & Quarters",
        "Full Screen", "Full Screen Tile", "Left of Screen", "Right of Screen", "Entire Screen",
        "Tile Window to Left of Screen", "Tile Window to Right of Screen",
        "Move Window to Desktop", "Move Window Back to Mac",
        "Hide Spelling and Grammar", "Hide Substitutions", "Start Dictation…",
    ])
}
