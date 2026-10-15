import AppKit
import Testing
@testable import Panely

/// The Go menu as AppKit built it in the test host's menu bar.
///
/// Its page-dependent bookmark items and the bookmark list are views of
/// their own (`GoPageBookmarkItems`, `GoBookmarksMenu`), so a page turn
/// re-renders only them. A view wrapped the wrong way inside a
/// `CommandMenu` can drop its items without any model test noticing — the
/// `.equatable()` that flattened the library tree was that kind of bug.
///
/// The menu belongs to the host app's own view model, which tests can't
/// reach, so this checks the menu's structure (and that its book-dependent
/// items are disabled with no book open), not its updates. Items are matched
/// by shortcut, not title, so the check holds in every app language.
@MainActor
struct GoMenuRenderingTests {

    @Test func goMenuListsTheBookmarkItemsInOrder() throws {
        let menu = try #require(goMenu(), "No menu with Go to Page… (⌘G) in the menu bar")

        #expect(Self.outline(of: menu) == """
            ⌘G
            —
            ⌘D
            ⇧⌘[
            ⇧⌘]
            ▸
            ·
            ·
            —
            ⇧⌘D
            —
            ⌘[
            ⌘]
            """)
    }

    /// No book is open in the test host: everything about the current
    /// page or book is disabled.
    @Test func bookItemsAreDisabledWithNoBookOpen() throws {
        let menu = try #require(goMenu(), "No menu with Go to Page… (⌘G) in the menu bar")
        menu.update()
        let disabled = menu.items
            .filter { !$0.isSeparatorItem && !$0.keyEquivalent.isEmpty && !$0.isEnabled }
            .map(Self.shortcut)
        #expect(disabled == ["⌘G", "⌘D", "⇧⌘[", "⇧⌘]", "⇧⌘D", "⌘[", "⌘]"])
    }

    // MARK: - Helpers

    private func goMenu() -> NSMenu? {
        NSApp.mainMenu?.items
            .compactMap(\.submenu)
            .first { menu in
                menu.items.contains { $0.keyEquivalent == "g" && $0.keyEquivalentModifierMask == .command }
            }
    }

    /// One line per item: its shortcut, `—` a separator, `▸` a submenu,
    /// `·` an item without a shortcut.
    private static func outline(of menu: NSMenu) -> String {
        menu.items.map { item in
            if item.isSeparatorItem { return "—" }
            if item.hasSubmenu { return "▸" }
            if item.keyEquivalent.isEmpty { return "·" }
            return shortcut(item)
        }
        .joined(separator: "\n")
    }

    private static func shortcut(_ item: NSMenuItem) -> String {
        let modifiers = item.keyEquivalentModifierMask
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + item.keyEquivalent.uppercased()
    }
}
