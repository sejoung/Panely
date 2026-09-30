import AppKit

/// Confirmation for the bulk bookmark removals. Removing one bookmark is a
/// single undoable-by-hand click, so it goes straight through; wiping a
/// book's worth (or everything) can't be taken back and asks first.
///
/// Lives outside `ReaderViewModel` so the view model stays free of AppKit
/// modals — the menu, sidebar, and toolbar all route through here.
@MainActor
enum BookmarkAlerts {
    static func removeAllInCurrentBook(_ viewModel: ReaderViewModel) {
        let count = viewModel.currentBookPageBookmarks.count
        guard count > 0 else { return }
        let confirmed = confirm(
            title: String(localized: "Remove all bookmarks in this book?"),
            count: count
        )
        if confirmed {
            viewModel.removeAllPageBookmarksInCurrentBook()
        }
    }

    static func removeAll(in book: BookmarkedBook, _ viewModel: ReaderViewModel) {
        guard !book.bookmarks.isEmpty else { return }
        let confirmed = confirm(
            title: String(localized: "Remove all bookmarks in “\(book.title)”?"),
            count: book.bookmarks.count
        )
        if confirmed {
            viewModel.pageBookmarks.removeAllPageBookmarks(forKey: book.key)
        }
    }

    static func removeAllEverywhere(_ viewModel: ReaderViewModel) {
        let count = viewModel.pageBookmarks.totalBookmarkCount
        guard count > 0 else { return }
        let confirmed = confirm(
            title: String(localized: "Remove all bookmarks in every book?"),
            count: count
        )
        if confirmed {
            viewModel.pageBookmarks.removeAll()
        }
    }

    private static func confirm(title: String, count: Int) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = String(localized: "Bookmarks to remove: \(count). This can't be undone.")
        alert.addButton(withTitle: String(localized: "Remove All"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
