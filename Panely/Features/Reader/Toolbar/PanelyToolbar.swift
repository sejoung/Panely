import SwiftUI

/// The floating reader toolbar. Presentation-only — every action is a
/// closure injected by the parent, so the toolbar has no opinion about
/// view models or controllers. The body composes five logical groups in
/// fixed left-to-right order: chrome → layout → fit/zoom → bookmarks →
/// navigation, separated by dividers.
struct PanelyToolbar: View {
    let layout: PageLayout
    let direction: ReadingDirection
    let fitMode: FitMode
    let sidebarPinned: Bool
    let onOpen: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    let onSetLayout: (PageLayout) -> Void
    let onToggleDirection: () -> Void
    let onSetFitMode: (FitMode) -> Void
    let onToggleSidebarPin: () -> Void
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    var autoFitOnResize: Bool = true
    var onToggleAutoFit: () -> Void = {}
    var toolbarPinned: Bool = false
    var onToggleToolbarPin: () -> Void = {}

    var showVolumeNav: Bool = false
    var canGoPreviousVolume: Bool = false
    var canGoNextVolume: Bool = false
    var onPreviousVolume: () -> Void = {}
    var onNextVolume: () -> Void = {}

    var hasSource: Bool = false
    var isBookFavorite: Bool = false
    var isPageBookmarked: Bool = false
    var onToggleFavorite: () -> Void = {}
    var onTogglePageBookmark: () -> Void = {}

    var thumbnailSidebarVisible: Bool = false
    var onToggleThumbnailSidebar: () -> Void = {}

    var body: some View {
        HStack(spacing: PanelySpacing.xs) {
            chromeGroup
            sectionDivider
            layoutGroup
            fitAndZoomGroup
            sectionDivider
            bookmarkGroup
            Spacer()
            navigationGroup
        }
        .padding(.horizontal, PanelySpacing.sm)
        .padding(.vertical, PanelySpacing.xs)
        .background(toolbarBackground)
    }

    // MARK: - Groups

    private var chromeGroup: some View {
        Group {
            PanelyIconButton(systemImage: "folder", action: onOpen)
                .help("Open Folder, CBZ, or ZIP… (⌘O)")

            PanelyIconButton(
                systemImage: sidebarPinned ? "pin.fill" : "pin",
                isActive: sidebarPinned,
                action: onToggleSidebarPin
            )
            .help(sidebarPinned ? "Unpin Library (⌃⌘S)" : "Pin Library (⌃⌘S)")

            PanelyIconButton(
                systemImage: toolbarPinned ? "pin.square.fill" : "pin.square",
                isActive: toolbarPinned,
                action: onToggleToolbarPin
            )
            .help(toolbarPinned ? "Unpin Toolbar (⌃⌘T)" : "Pin Toolbar (⌃⌘T)")
        }
    }

    // Segmented layout picker. One tap to switch directly to any mode — no
    // cycle round-trip that would otherwise drag the user through `vertical`
    // (the destructive transition) just to get from `single` to `double`.
    private var layoutGroup: some View {
        Group {
            PanelyIconButton(
                systemImage: "rectangle.portrait",
                isActive: layout == .single,
                action: { onSetLayout(.single) }
            )
            .help("Single Page (⌘⇧1)")

            PanelyIconButton(
                systemImage: "rectangle.split.2x1",
                isActive: layout == .double,
                action: { onSetLayout(.double) }
            )
            .help("Double Page (⌘⇧2)")

            PanelyIconButton(
                // `rectangle.stack` keeps the layout segments in the same
                // "container shape" visual family as the single/double icons,
                // and avoids colliding with the fit-height segment below
                // (which legitimately owns `arrow.up.and.down` as part of the
                // directional-resize triplet).
                systemImage: "rectangle.stack",
                isActive: layout == .vertical,
                action: { onSetLayout(.vertical) }
            )
            .help("Vertical Scroll (⌘⇧3)")

            PanelyIconButton(
                systemImage: directionSymbol,
                action: onToggleDirection
            )
            .disabled(layout.isContinuous)
            .help(directionHelp)
        }
    }

    // Segmented fit picker — same direct-selection pattern as the layout
    // segments above. Mirrors the existing `⌘1/⌘2/⌘3` shortcuts so users
    // see "the same three options" in toolbar and keyboard.
    private var fitAndZoomGroup: some View {
        Group {
            PanelyIconButton(
                systemImage: "arrow.up.left.and.arrow.down.right",
                isActive: fitMode == .fitScreen,
                action: { onSetFitMode(.fitScreen) }
            )
            .help("Fit to Screen (⌘1)")

            PanelyIconButton(
                systemImage: "arrow.left.and.right",
                isActive: fitMode == .fitWidth,
                action: { onSetFitMode(.fitWidth) }
            )
            .help("Fit Width (⌘2)")

            PanelyIconButton(
                systemImage: "arrow.up.and.down",
                isActive: fitMode == .fitHeight,
                action: { onSetFitMode(.fitHeight) }
            )
            .help("Fit Height (⌘3)")

            PanelyIconButton(
                systemImage: "minus.magnifyingglass",
                action: onZoomOut
            )
            .help("Zoom Out (⌘−)")

            PanelyIconButton(
                systemImage: "plus.magnifyingglass",
                action: onZoomIn
            )
            .help("Zoom In (⌘+)")

            PanelyIconButton(
                systemImage: autoFitOnResize ? "lock.open" : "lock.fill",
                isActive: !autoFitOnResize,
                action: onToggleAutoFit
            )
            .help(autoFitOnResize
                  ? "Lock view size (don't auto-fit on resize) (⌘L)"
                  : "Unlock view size (auto-fit on resize) (⌘L)")
        }
    }

    private var bookmarkGroup: some View {
        Group {
            PanelyIconButton(
                systemImage: isBookFavorite ? "star.fill" : "star",
                isActive: isBookFavorite,
                action: onToggleFavorite
            )
            .disabled(!hasSource)
            .help(isBookFavorite ? "Remove from Favorites (⌘⇧D)" : "Add to Favorites (⌘⇧D)")

            PanelyIconButton(
                systemImage: isPageBookmarked ? "bookmark.fill" : "bookmark",
                isActive: isPageBookmarked,
                action: onTogglePageBookmark
            )
            .disabled(!hasSource)
            .help(isPageBookmarked ? "Remove Page Bookmark (⌘D)" : "Bookmark Current Page (⌘D)")

            PanelyIconButton(
                systemImage: "square.stack",
                isActive: thumbnailSidebarVisible,
                action: onToggleThumbnailSidebar
            )
            .disabled(!hasSource)
            .help(thumbnailSidebarVisible
                  ? "Hide Thumbnails (⌃⌘P)"
                  : "Show Thumbnails (⌃⌘P)")
        }
    }

    @ViewBuilder
    private var navigationGroup: some View {
        if showVolumeNav {
            PanelyIconButton(systemImage: "chevron.backward.2", action: onPreviousVolume)
                .disabled(!canGoPreviousVolume)
                .help("Previous Volume (⌘[)")
        }

        PanelyIconButton(systemImage: "chevron.left", action: onPrev)
            .help("Previous Page (\(previousKeyHint))")

        PanelyIconButton(systemImage: "chevron.right", action: onNext)
            .help("Next Page (\(nextKeyHint) or Space)")

        if showVolumeNav {
            PanelyIconButton(systemImage: "chevron.forward.2", action: onNextVolume)
                .disabled(!canGoNextVolume)
                .help("Next Volume (⌘])")
        }
    }

    // MARK: - Chrome

    private var sectionDivider: some View {
        Divider()
            .frame(height: 18)
            .padding(.horizontal, PanelySpacing.xs)
    }

    private var toolbarBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PanelyColor.borderSubtle, lineWidth: 1)
            )
    }

    // MARK: - Direction-aware labels

    private var directionSymbol: String {
        direction.isRTL ? "arrow.left" : "arrow.right"
    }

    private var directionHelp: String {
        if layout.isContinuous {
            return "Reading direction is fixed in vertical mode"
        }
        return direction.isRTL ? "Read Left to Right" : "Read Right to Left"
    }

    private var previousKeyHint: String {
        direction.isRTL ? "→" : "←"
    }

    private var nextKeyHint: String {
        direction.isRTL ? "←" : "→"
    }
}

#Preview {
    PanelyToolbar(
        layout: .double,
        direction: .rightToLeft,
        fitMode: .fitScreen,
        sidebarPinned: true,
        onOpen: {},
        onPrev: {},
        onNext: {},
        onSetLayout: { _ in },
        onToggleDirection: {},
        onSetFitMode: { _ in },
        onToggleSidebarPin: {},
        showVolumeNav: true,
        canGoPreviousVolume: true,
        canGoNextVolume: false,
        onPreviousVolume: {},
        onNextVolume: {}
    )
    .padding(PanelySpacing.xl)
    .frame(width: 640)
    .background(PanelyColor.bgPrimary)
}
