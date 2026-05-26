import SwiftUI

struct PanelyToolbarState: Equatable {
    var layout: PageLayout
    var direction: ReadingDirection
    var fitMode: FitMode
    var sidebarPinned: Bool
    var autoFitOnResize = true
    var toolbarPinned = false
    var showVolumeNav = false
    var canGoPreviousVolume = false
    var canGoNextVolume = false
    var hasSource = false
    var isBookFavorite = false
    var isPageBookmarked = false
    var thumbnailSidebarVisible = false
    /// True when the scroll view's magnification matches the fit baseline.
    /// Gates the fit-mode button highlight — once the user zooms in/out,
    /// they're no longer "at" `fitMode` so no fit button should look
    /// selected until they snap back (via the fit button or reset zoom).
    var isAtFit = true
}

struct PanelyToolbarActions {
    var onOpen: () -> Void = {}
    var onPrev: () -> Void = {}
    var onNext: () -> Void = {}
    var onSetLayout: (PageLayout) -> Void = { _ in }
    var onToggleDirection: () -> Void = {}
    var onSetFitMode: (FitMode) -> Void = { _ in }
    var onToggleSidebarPin: () -> Void = {}
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    var onToggleAutoFit: () -> Void = {}
    var onToggleToolbarPin: () -> Void = {}
    var onPreviousVolume: () -> Void = {}
    var onNextVolume: () -> Void = {}
    var onToggleFavorite: () -> Void = {}
    var onTogglePageBookmark: () -> Void = {}
    var onToggleThumbnailSidebar: () -> Void = {}
}

/// The floating reader toolbar. Presentation-only — every action is a
/// closure injected by the parent, so the toolbar has no opinion about
/// view models or controllers. The body composes five logical groups in
/// fixed left-to-right order: chrome → layout → fit/zoom → bookmarks →
/// navigation, separated by dividers.
struct PanelyToolbar: View {
    let state: PanelyToolbarState
    let actions: PanelyToolbarActions

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
            PanelyIconButton(systemImage: "folder", action: actions.onOpen)
                .help("Open Folder, CBZ, or ZIP… (⌘O)")

            PanelyIconButton(
                systemImage: state.sidebarPinned ? "pin.fill" : "pin",
                isActive: state.sidebarPinned,
                action: actions.onToggleSidebarPin
            )
            .help(state.sidebarPinned ? "Unpin Library (⌃⌘S)" : "Pin Library (⌃⌘S)")

            PanelyIconButton(
                systemImage: state.toolbarPinned ? "pin.square.fill" : "pin.square",
                isActive: state.toolbarPinned,
                action: actions.onToggleToolbarPin
            )
            .help(state.toolbarPinned ? "Unpin Toolbar (⌃⌘T)" : "Pin Toolbar (⌃⌘T)")
        }
    }

    // Segmented layout picker. One tap to switch directly to any mode — no
    // cycle round-trip that would otherwise drag the user through `vertical`
    // (the destructive transition) just to get from `single` to `double`.
    private var layoutGroup: some View {
        Group {
            PanelyIconButton(
                systemImage: "rectangle.portrait",
                isActive: state.layout == .single,
                action: { actions.onSetLayout(.single) }
            )
            .help("Single Page (⌘⇧1)")

            PanelyIconButton(
                systemImage: "rectangle.split.2x1",
                isActive: state.layout == .double,
                action: { actions.onSetLayout(.double) }
            )
            .help("Double Page (⌘⇧2)")

            PanelyIconButton(
                // `rectangle.stack` keeps the layout segments in the same
                // "container shape" visual family as the single/double icons,
                // and avoids colliding with the fit-height segment below
                // (which legitimately owns `arrow.up.and.down` as part of the
                // directional-resize triplet).
                systemImage: "rectangle.stack",
                isActive: state.layout == .vertical,
                action: { actions.onSetLayout(.vertical) }
            )
            .help("Vertical Scroll (⌘⇧3)")

            PanelyIconButton(
                systemImage: directionSymbol,
                action: actions.onToggleDirection
            )
            .disabled(state.layout.isContinuous)
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
                isActive: state.fitMode == .fitScreen && state.isAtFit,
                action: { actions.onSetFitMode(.fitScreen) }
            )
            .help("Fit to Screen (⌘1)")

            PanelyIconButton(
                systemImage: "arrow.left.and.right",
                isActive: state.fitMode == .fitWidth && state.isAtFit,
                action: { actions.onSetFitMode(.fitWidth) }
            )
            .help("Fit Width (⌘2)")

            PanelyIconButton(
                systemImage: "arrow.up.and.down",
                isActive: state.fitMode == .fitHeight && state.isAtFit,
                action: { actions.onSetFitMode(.fitHeight) }
            )
            .help("Fit Height (⌘3)")

            PanelyIconButton(
                systemImage: "minus.magnifyingglass",
                action: actions.onZoomOut
            )
            .help("Zoom Out (⌘−)")

            PanelyIconButton(
                systemImage: "plus.magnifyingglass",
                action: actions.onZoomIn
            )
            .help("Zoom In (⌘+)")

            PanelyIconButton(
                systemImage: state.autoFitOnResize ? "lock.open" : "lock.fill",
                isActive: !state.autoFitOnResize,
                action: actions.onToggleAutoFit
            )
            .help(state.autoFitOnResize
                  ? "Lock view size (don't auto-fit on resize) (⌘L)"
                  : "Unlock view size (auto-fit on resize) (⌘L)")
        }
    }

    private var bookmarkGroup: some View {
        Group {
            PanelyIconButton(
                systemImage: state.isBookFavorite ? "star.fill" : "star",
                isActive: state.isBookFavorite,
                action: actions.onToggleFavorite
            )
            .disabled(!state.hasSource)
            .help(state.isBookFavorite ? "Remove from Favorites (⌘⇧D)" : "Add to Favorites (⌘⇧D)")

            PanelyIconButton(
                systemImage: state.isPageBookmarked ? "bookmark.fill" : "bookmark",
                isActive: state.isPageBookmarked,
                action: actions.onTogglePageBookmark
            )
            .disabled(!state.hasSource)
            .help(state.isPageBookmarked ? "Remove Page Bookmark (⌘D)" : "Bookmark Current Page (⌘D)")

            PanelyIconButton(
                systemImage: "square.stack",
                isActive: state.thumbnailSidebarVisible,
                action: actions.onToggleThumbnailSidebar
            )
            .disabled(!state.hasSource)
            .help(state.thumbnailSidebarVisible
                  ? "Hide Thumbnails (⌃⌘P)"
                  : "Show Thumbnails (⌃⌘P)")
        }
    }

    @ViewBuilder
    private var navigationGroup: some View {
        if state.showVolumeNav {
            PanelyIconButton(systemImage: "chevron.backward.2", action: actions.onPreviousVolume)
                .disabled(!state.canGoPreviousVolume)
                .help("Previous Volume (⌘[)")
        }

        PanelyIconButton(systemImage: "chevron.left", action: actions.onPrev)
            .help("Previous Page (\(previousKeyHint))")

        PanelyIconButton(systemImage: "chevron.right", action: actions.onNext)
            .help("Next Page (\(nextKeyHint) or Space)")

        if state.showVolumeNav {
            PanelyIconButton(systemImage: "chevron.forward.2", action: actions.onNextVolume)
                .disabled(!state.canGoNextVolume)
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
        state.direction.isRTL ? "arrow.left" : "arrow.right"
    }

    private var directionHelp: String {
        if state.layout.isContinuous {
            return "Reading direction is fixed in vertical mode"
        }
        return state.direction.isRTL ? "Read Left to Right" : "Read Right to Left"
    }

    private var previousKeyHint: String {
        state.direction.isRTL ? "→" : "←"
    }

    private var nextKeyHint: String {
        state.direction.isRTL ? "←" : "→"
    }
}

#Preview {
    PanelyToolbar(
        state: PanelyToolbarState(
            layout: .double,
            direction: .rightToLeft,
            fitMode: .fitScreen,
            sidebarPinned: true,
            showVolumeNav: true,
            canGoPreviousVolume: true,
            canGoNextVolume: false
        ),
        actions: PanelyToolbarActions()
    )
    .padding(PanelySpacing.xl)
    .frame(width: 640)
    .background(PanelyColor.bgPrimary)
}
