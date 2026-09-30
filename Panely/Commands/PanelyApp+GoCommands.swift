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
        CommandMenu("Go") {
            Button("Go to Page…") {
                promptJumpToPage(viewModel: viewModel)
            }
            .keyboardShortcut("g", modifiers: .command)
            .disabled(!viewModel.hasSource || viewModel.totalPages <= 1)

            Divider()

            Button(viewModel.isCurrentPageBookmarked ? "Remove Page Bookmark" : "Add Page Bookmark") {
                viewModel.toggleCurrentPageBookmark()
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(!viewModel.hasSource)

            Button("Previous Bookmark") {
                viewModel.jumpToPreviousBookmark()
            }
            .keyboardShortcut("[", modifiers: [.command, .shift])
            .disabled(!viewModel.canGoPreviousBookmark)

            Button("Next Bookmark") {
                viewModel.jumpToNextBookmark()
            }
            .keyboardShortcut("]", modifiers: [.command, .shift])
            .disabled(!viewModel.canGoNextBookmark)

            bookmarksMenu

            Button("Remove All Bookmarks in This Book…") {
                BookmarkAlerts.removeAllInCurrentBook(viewModel)
            }
            .disabled(!viewModel.hasPageBookmarks)

            Button("Remove All Bookmarks…") {
                BookmarkAlerts.removeAllEverywhere(viewModel)
            }
            .disabled(!viewModel.hasAnyPageBookmarks)

            Divider()

            Button(viewModel.isCurrentBookFavorite ? "Remove from Favorites" : "Add to Favorites") {
                viewModel.toggleFavoriteForCurrentBook()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!viewModel.hasSource)

            Divider()

            Button("Previous Volume") {
                viewModel.stepToPreviousVolume()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!viewModel.canStepToPreviousVolume)

            Button("Next Volume") {
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
        Menu("Bookmarks") {
            if current.isEmpty && others.isEmpty {
                Text("No Bookmarks")
            }
            ForEach(current) { bookmark in
                Button("Page \(bookmark.pageIndex + 1)") {
                    viewModel.jumpToBookmark(bookmark)
                }
            }
            if !current.isEmpty && !others.isEmpty {
                Divider()
            }
            ForEach(others) { book in
                Menu(book.qualifiedTitle) {
                    ForEach(book.bookmarks) { bookmark in
                        Button("Page \(bookmark.pageIndex + 1)") {
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
    alert.messageText = String(localized: "Go to Page")
    alert.informativeText = String(localized: "Enter a page number (1 – \(viewModel.totalPages)):")
    alert.addButton(withTitle: String(localized: "Go"))
    alert.addButton(withTitle: String(localized: "Cancel"))

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
