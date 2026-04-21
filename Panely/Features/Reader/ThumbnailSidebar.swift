import SwiftUI

/// Right-side page thumbnail panel. Lazily renders cells via `LazyVStack`
/// so a 1000-page book only materializes the ~dozen cells on screen; each
/// cell kicks off its own async thumbnail fetch via `ThumbnailLoader`.
struct ThumbnailSidebar: View {
    let pages: [ComicPage]
    let pageDimensions: [CGSize]
    let currentPageIndex: Int
    let onJump: (Int) -> Void
    let onClose: () -> Void

    private let sidebarWidth: CGFloat = 148
    private let cellWidth: CGFloat = 112
    private let defaultAspectRatio: CGFloat = 1.5

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()
                .overlay(PanelyColor.borderSubtle)

            if pages.isEmpty {
                emptyState
            } else {
                thumbnailList
            }
        }
        .frame(width: sidebarWidth)
        .background(PanelyColor.bgSecondary)
    }

    private var header: some View {
        HStack(spacing: PanelySpacing.sm) {
            Image(systemName: "square.stack")
                .foregroundStyle(PanelyColor.textSecondary)
            Text("Pages")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textPrimary)
            Spacer(minLength: 0)
            PanelyIconButton(systemImage: "xmark", action: onClose)
                .help("Hide Thumbnails (⌃⌘P)")
        }
        .padding(.horizontal, PanelySpacing.sm)
        .padding(.vertical, PanelySpacing.xs)
    }

    private var thumbnailList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: PanelySpacing.sm) {
                    ForEach(Array(pages.enumerated()), id: \.element.id) { idx, page in
                        ThumbnailCell(
                            page: page,
                            cellSize: cellSize(forPageAt: idx),
                            pageNumber: idx + 1,
                            isActive: idx == currentPageIndex,
                            onTap: { onJump(idx) }
                        )
                        .id(idx)
                    }
                }
                .padding(PanelySpacing.sm)
            }
            .onChange(of: currentPageIndex) { _, new in
                // Keep the active thumbnail in view when the user pages with
                // the keyboard / slider. `center` keeps it from jittering on
                // the edges.
                withAnimation(PanelyMotion.uiReveal) {
                    proxy.scrollTo(new, anchor: .center)
                }
            }
            .onAppear {
                proxy.scrollTo(currentPageIndex, anchor: .center)
            }
        }
    }

    private var emptyState: some View {
        VStack {
            Spacer()
            Text("No pages")
                .font(PanelyTypography.caption)
                .foregroundStyle(PanelyColor.textSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func cellSize(forPageAt index: Int) -> CGSize {
        // Use the known dimensions when available (vertical mode pre-fetches
        // all of them) so webtoon-tall strips get long cells and normal
        // portrait comics get shorter ones. Fall back to a 2:3 portrait
        // when the dimension hasn't been fetched yet.
        if pageDimensions.indices.contains(index) {
            let dim = pageDimensions[index]
            if dim.width > 0, dim.height > 0 {
                let ratio = dim.height / dim.width
                // Clamp extreme ratios so a single outlier doesn't stretch
                // the sidebar; webtoons can legitimately be 1:10 but the
                // scroll would feel weird in a narrow panel.
                let clamped = min(max(ratio, 0.3), 3.0)
                return CGSize(width: cellWidth, height: cellWidth * clamped)
            }
        }
        return CGSize(width: cellWidth, height: cellWidth * defaultAspectRatio)
    }
}

private struct ThumbnailCell: View {
    let page: ComicPage
    let cellSize: CGSize
    let pageNumber: Int
    let isActive: Bool
    let onTap: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 4) {
                ZStack {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(PanelyColor.bgTertiary)

                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                }
                .frame(width: cellSize.width, height: cellSize.height)
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .stroke(
                            isActive ? PanelyColor.accentPrimary : Color.clear,
                            lineWidth: 2
                        )
                )

                Text("\(pageNumber)")
                    .font(PanelyTypography.caption)
                    .foregroundStyle(isActive ? PanelyColor.accentPrimary : PanelyColor.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .task(id: page.id) {
            image = await ThumbnailLoader.shared.thumbnail(for: page)
        }
    }
}
