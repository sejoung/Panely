import AppKit
import SwiftUI

extension PanelyApp {
    /// The Go menu: page-jump prompt, per-page bookmark toggle + step, book
    /// favorite toggle, and sibling-volume stepping. Dividers separate the
    /// four concerns; shortcuts deliberately don't collide with the View
    /// menu's `⌘1-3` fit-mode group.
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

            Divider()

            Button(viewModel.isCurrentBookFavorite ? "Remove from Favorites" : "Add to Favorites") {
                viewModel.toggleFavoriteForCurrentBook()
            }
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .disabled(!viewModel.hasSource)

            Divider()

            Button("Previous Volume") {
                viewModel.previousVolume()
            }
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!viewModel.canGoPreviousVolume)

            Button("Next Volume") {
                viewModel.nextVolume()
            }
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!viewModel.canGoNextVolume)
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
    alert.messageText = "Go to Page"
    alert.informativeText = "Enter a page number (1 – \(viewModel.totalPages)):"
    alert.addButton(withTitle: "Go")
    alert.addButton(withTitle: "Cancel")

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
