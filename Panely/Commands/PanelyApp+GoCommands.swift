import AppKit
import SwiftUI

extension PanelyApp {
    /// The Go menu: page-jump prompt, per-page bookmark toggle + step + list,
    /// book favorite toggle, and sibling-volume stepping. Dividers separate
    /// the four concerns; shortcuts deliberately don't collide with the View
    /// menu's `⌘1-3` fit-mode group.
    ///
    /// Volume stepping also answers to bare `[` / `]` while the viewer has
    /// focus (see `ViewerArea`). Those aren't menu shortcuts on purpose: a
    /// modifier-less key equivalent would swallow the bracket keys in every
    /// text field too.
    @CommandsBuilder
    var goCommands: some Commands {
        CommandMenu(String(localized: "Go", bundle: .localized)) {
            Button(String(localized: "Go to Page…", bundle: .localized)) {
                promptJumpToPage(viewModel: viewModel)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!viewModel.hasSource || viewModel.totalPages <= 1)

            Divider()

            Button(
                viewModel.isCurrentPageBookmarked
                    ? String(localized: "Remove Page Bookmark", bundle: .localized)
                    : String(localized: "Add Page Bookmark", bundle: .localized)
            ) {
                viewModel.toggleCurrentPageBookmark()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!viewModel.hasSource)

            Button(String(localized: "Previous Bookmark", bundle: .localized)) {
                viewModel.jumpToPreviousBookmark()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(!viewModel.canGoPreviousBookmark)

            Button(String(localized: "Next Bookmark", bundle: .localized)) {
                viewModel.jumpToNextBookmark()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(!viewModel.canGoNextBookmark)

            bookmarksMenu

            Button(String(localized: "Remove All Bookmarks in This Book…", bundle: .localized)) {
                BookmarkAlerts.removeAllInCurrentBook(viewModel)
            }
            .disabled(!viewModel.hasPageBookmarks)

            Button(String(localized: "Remove All Bookmarks…", bundle: .localized)) {
                BookmarkAlerts.removeAllEverywhere(viewModel)
            }
            .disabled(!viewModel.hasAnyPageBookmarks)

            Divider()

            Button(
                viewModel.isCurrentBookFavorite
                    ? String(localized: "Remove from Favorites", bundle: .localized)
                    : String(localized: "Add to Favorites", bundle: .localized)
            ) {
                viewModel.toggleFavoriteForCurrentBook()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!viewModel.hasSource)

            Divider()

            Button(String(localized: "Previous Volume", bundle: .localized)) {
                viewModel.stepToPreviousVolume()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!viewModel.canStepToPreviousVolume)

            Button(String(localized: "Next Volume", bundle: .localized)) {
                viewModel.stepToNextVolume()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!viewModel.canStepToNextVolume)
        }
    }

    /// Every bookmark as a menu: the open book's pages first, then one
    /// submenu per other bookmarked book.
    @ViewBuilder
    private var bookmarksMenu: some View {
        let current = viewModel.currentBookPageBookmarks
        let others = viewModel.otherBookmarkedBooks
        Menu(String(localized: "Bookmarks", bundle: .localized)) {
            if current.isEmpty && others.isEmpty {
                Text(String(localized: "No Bookmarks", bundle: .localized))
            }
            ForEach(current) { bookmark in
                Button(String(localized: "Page \(bookmark.pageIndex + 1)", bundle: .localized)) {
                    viewModel.jumpToBookmark(bookmark)
                }
            }
            if !current.isEmpty && !others.isEmpty {
                Divider()
            }
            ForEach(others) { book in
                Menu(book.qualifiedTitle) {
                    ForEach(book.bookmarks) { bookmark in
                        Button(String(localized: "Page \(bookmark.pageIndex + 1)", bundle: .localized)) {
                            viewModel.openBookmark(bookmark, in: book)
                        }
                    }
                }
            }
        }
    }
}

/// Modal "Go to Page" prompt. Lives outside the App type so the menu
/// builder stays declarative — alerts pull in AppKit machinery (NSAlert,
/// NSTextField) that's awkward inside `@CommandsBuilder`.
@MainActor
func promptJumpToPage(viewModel: ReaderViewModel) {
    guard viewModel.hasSource, viewModel.totalPages > 1 else { return }

    let alert = NSAlert()
    alert.messageText = String(localized: "Go to Page", bundle: .localized)
    alert.informativeText = String(localized: "Enter a page number (1 – \(viewModel.totalPages)):", bundle: .localized)
    alert.addButton(withTitle: String(localized: "Go", bundle: .localized))
    alert.addButton(withTitle: String(localized: "Cancel", bundle: .localized))

    let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
    field.placeholderString = "\(viewModel.currentPageNumber)"
    field.stringValue = "\(viewModel.currentPageNumber)"
    field.alignment = .center
    alert.accessoryView = field
    alert.window.initialFirstResponder = field

    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
    guard let parsed = Int(trimmed) else { return }
    viewModel.jump(toPageNumber: parsed)
}
