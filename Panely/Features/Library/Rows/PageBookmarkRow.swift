import SwiftUI

struct PageBookmarkRow: View {
    let bookmark: PageBookmark
    /// The bookmarked page, when its book is the one open. Lets the row show
    /// a thumbnail; rows for other books fall back to the bookmark glyph.
    var page: ComicPage? = nil
    let isCurrent: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    private let thumbnailSize = CGSize(width: 24, height: 34)

    var body: some View {
        HStack(spacing: PanelySpacing.xs) {
            Button(action: onTap) {
                HStack(spacing: PanelySpacing.sm) {
                    leading
                    Text("Page \(bookmark.pageIndex + 1)")
                        .font(PanelyTypography.body)
                        .foregroundStyle(isCurrent ? PanelyColor.accentPrimary : PanelyColor.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
                .padding(.vertical, 2)
            }
            .buttonStyle(.plain)

            // Always laid out (so the row doesn't reflow on hover), only
            // visible and clickable while the pointer is on the row.
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(PanelyColor.textSecondary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove Bookmark")
            .accessibilityLabel(Text("Remove Bookmark"))
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
        }
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Remove Bookmark", role: .destructive, action: onRemove)
        }
        .task(id: page?.id) {
            thumbnail = nil
            guard let page else { return }
            let loaded = await ThumbnailLoader.shared.thumbnail(for: page)
            guard !Task.isCancelled else { return }
            thumbnail = loaded
        }
    }

    @ViewBuilder
    private var leading: some View {
        if page != nil {
            ZStack {
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(PanelyColor.bgTertiary)
                if let thumbnail {
                    Image(nsImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                }
            }
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(isCurrent ? PanelyColor.accentPrimary : PanelyColor.borderSubtle, lineWidth: 1)
            )
        } else {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(isCurrent ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
                .frame(width: 16)
        }
    }
}

/// A book in the "Bookmarks in Other Books" list: its title and how many
/// pages are marked. Tapping expands it; the pages underneath open the book.
struct BookmarkedBookRow: View {
    let book: BookmarkedBook
    let onTap: () -> Void
    let onRemoveAll: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: PanelySpacing.sm) {
                Image(systemName: "book.closed")
                    .foregroundStyle(PanelyColor.textSecondary)
                    .frame(width: 16)
                Text(verbatim: book.title)
                    .font(PanelyTypography.body)
                    .foregroundStyle(PanelyColor.textPrimary)
                    .lineLimit(1)
                    // Keep the trailing volume number visible (see FileNodeRow).
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Text(verbatim: "\(book.bookmarks.count)")
                    .font(PanelyTypography.caption)
                    .foregroundStyle(PanelyColor.textSecondary)
            }
            .contentShape(Rectangle())
            .padding(.vertical, 2)
            .help(book.qualifiedTitle)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove This Book's Bookmarks…", role: .destructive, action: onRemoveAll)
        }
    }
}
