import SwiftUI

struct PanelyToolbarState: Equatable {
    var layout: PageLayout
    var direction: ReadingDirection
    var fitMode: FitMode
    var sidebarPinned: Bool
    var autoFitOnResize = true
    var toolbarPinned = false
    var showVolumeNav = false
    /// Whether the volume buttons respond. True when there is a neighbour to
    /// step to — and also when the book's folder is unreadable, so pressing
    /// one can offer the folder grant instead of sitting there disabled.
    var canGoPreviousVolume = false
    var canGoNextVolume = false
    var hasSource = false
    var isBookFavorite = false
    var isPageBookmarked = false
    var thumbnailSidebarVisible = false
    /// Double-page standalone-cover offset (see `SpreadCalculator`). Drives the
    /// offset toggle's active state; the button itself is shown only in double.
    var doublePageCoverAlone = false
    /// True when the scroll view's magnification matches the fit baseline.
    /// Gates the fit-mode button highlight — once the user zooms in/out,
    /// they're no longer "at" `fitMode` so no fit button should look
    /// selected until they snap back (via the fit button or reset zoom).
    var isAtFit = true
    /// Bookmarks in the open book (sorted by page) and the span of pages on
    /// screen, for the bookmark menu's list and its "you are here" mark.
    var pageBookmarks: [PageBookmark] = []
    var visiblePageRange: Range<Int> = 0..<0
    var canGoPreviousBookmark = false
    var canGoNextBookmark = false
    /// Bookmarked books other than the open one, most recent first.
    var otherBookmarkedBooks: [BookmarkedBook] = []
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
    var onToggleDoublePageCoverAlone: () -> Void = {}
    var onJumpToBookmark: (PageBookmark) -> Void = { _ in }
    var onPreviousBookmark: () -> Void = {}
    var onNextBookmark: () -> Void = {}
    var onOpenBookmark: (PageBookmark, BookmarkedBook) -> Void = { _, _ in }
    var onRemoveAllPageBookmarks: () -> Void = {}
}

/// The floating reader toolbar. Presentation-only — every action is a
/// closure injected by the parent, so the toolbar has no opinion about
/// view models or controllers. The body composes five logical groups in
/// fixed left-to-right order: chrome → layout → fit/zoom → bookmarks →
/// navigation, separated by dividers.
///
/// Every control carries a `toolbarHint`: the label that appears under it on
/// hover (see `ToolbarHint`) and that VoiceOver reads.
///
/// The row is wider than a small window (or a window with the library
/// pinned), and an overflowing `HStack` clips both ends — which would cut
/// off exactly the page/volume buttons. So when it doesn't fit, the widest
/// groups fold into menus instead: fit/zoom first, then layout.
struct PanelyToolbar: View {
    let state: PanelyToolbarState
    let actions: PanelyToolbarActions

    @State private var hoveredHint: ToolbarHint?

    /// `previewHint` shows a control's hint as if it were hovered — for
    /// previews and manual screenshots, where there is no pointer.
    init(
        state: PanelyToolbarState,
        actions: PanelyToolbarActions,
        previewHint: ToolbarHint? = nil
    ) {
        self.state = state
        self.actions = actions
        _hoveredHint = State(initialValue: previewHint)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            row(collapsingFitAndZoom: false, collapsingLayout: false)
            row(collapsingFitAndZoom: true, collapsingLayout: false)
            row(collapsingFitAndZoom: true, collapsingLayout: true)
        }
        .padding(.horizontal, PanelySpacing.sm)
        .padding(.vertical, PanelySpacing.xs)
        .background(toolbarBackground)
        .overlayPreferenceValue(ToolbarHintAnchorKey.self) { anchors in
            hintOverlay(anchors: anchors)
        }
        .animation(PanelyMotion.uiReveal, value: hoveredHint?.id)
    }

    private func row(collapsingFitAndZoom: Bool, collapsingLayout: Bool) -> some View {
        HStack(spacing: PanelySpacing.xs) {
            chromeGroup
            sectionDivider
            if collapsingLayout {
                layoutMenu
            } else {
                layoutGroup
            }
            if collapsingFitAndZoom {
                fitAndZoomMenu
            } else {
                fitAndZoomGroup
            }
            sectionDivider
            bookmarkGroup
            Spacer(minLength: PanelySpacing.sm)
            navigationGroup
        }
    }

    // MARK: - Groups

    private var chromeGroup: some View {
        Group {
            iconButton(
                "open", "folder",
                hint: "Open Folder, CBZ/CBR, or ZIP/RAR… (⌘O)",
                action: actions.onOpen
            )

            iconButton(
                "pinLibrary", state.sidebarPinned ? "pin.fill" : "pin",
                hint: state.sidebarPinned ? "Unpin Library (⌃⌘S)" : "Pin Library (⌃⌘S)",
                isActive: state.sidebarPinned,
                action: actions.onToggleSidebarPin
            )

            iconButton(
                "pinToolbar", state.toolbarPinned ? "pin.square.fill" : "pin.square",
                hint: state.toolbarPinned ? "Unpin Toolbar (⌃⌘T)" : "Pin Toolbar (⌃⌘T)",
                isActive: state.toolbarPinned,
                action: actions.onToggleToolbarPin
            )
        }
    }

    // Segmented layout picker. One tap to switch directly to any mode — no
    // cycle round-trip that would otherwise drag the user through `vertical`
    // (the destructive transition) just to get from `single` to `double`.
    private var layoutGroup: some View {
        Group {
            iconButton(
                "layoutSingle", "rectangle.portrait",
                hint: "Single Page (⌘⇧1)",
                isActive: state.layout == .single,
                action: { actions.onSetLayout(.single) }
            )

            iconButton(
                "layoutDouble", "rectangle.split.2x1",
                hint: "Double Page (⌘⇧2)",
                isActive: state.layout == .double,
                action: { actions.onSetLayout(.double) }
            )

            iconButton(
                // `rectangle.stack` keeps the layout segments in the same
                // "container shape" visual family as the single/double icons,
                // and avoids colliding with the fit-height segment below
                // (which legitimately owns `arrow.up.and.down` as part of the
                // directional-resize triplet).
                "layoutVertical", "rectangle.stack",
                hint: "Vertical Scroll (⌘⇧3)",
                isActive: state.layout == .vertical,
                action: { actions.onSetLayout(.vertical) }
            )

            iconButton(
                "direction", directionSymbol,
                hint: directionHint,
                isEnabled: !state.layout.isContinuous,
                action: actions.onToggleDirection
            )

            // Standalone-cover spread offset — only meaningful (and only
            // shown) in double-page mode. Realigns pairing so a lone cover
            // doesn't push every facing spread one page out of step.
            if state.layout == .double {
                iconButton(
                    "coverAlone", "book.pages",
                    hint: "Offset spread (standalone cover)",
                    isActive: state.doublePageCoverAlone,
                    action: actions.onToggleDoublePageCoverAlone
                )
            }
        }
    }

    /// `layoutGroup` folded into one menu for narrow windows.
    private var layoutMenu: some View {
        PanelyIconMenu(systemImage: layoutSymbol, accessibilityTitle: "Page Layout") {
            menuItem("Single Page", isSelected: state.layout == .single) {
                actions.onSetLayout(.single)
            }
            menuItem("Double Page", isSelected: state.layout == .double) {
                actions.onSetLayout(.double)
            }
            menuItem("Vertical Scroll", isSelected: state.layout == .vertical) {
                actions.onSetLayout(.vertical)
            }

            Divider()

            Button(directionHint, action: actions.onToggleDirection)
                .disabled(state.layout.isContinuous)

            if state.layout == .double {
                menuItem("Offset spread (standalone cover)", isSelected: state.doublePageCoverAlone) {
                    actions.onToggleDoublePageCoverAlone()
                }
            }
        }
        .toolbarHint("layoutMenu", "Page Layout", hovered: $hoveredHint)
    }

    private var layoutSymbol: String {
        switch state.layout {
        case .single: "rectangle.portrait"
        case .double: "rectangle.split.2x1"
        case .vertical: "rectangle.stack"
        }
    }

    // Segmented fit picker — same direct-selection pattern as the layout
    // segments above. Mirrors the existing `⌘1/⌘2/⌘3` shortcuts so users
    // see "the same three options" in toolbar and keyboard.
    private var fitAndZoomGroup: some View {
        Group {
            iconButton(
                "fitScreen", "arrow.up.left.and.arrow.down.right",
                hint: "Fit to Screen (⌘1)",
                isActive: state.fitMode == .fitScreen && state.isAtFit,
                action: { actions.onSetFitMode(.fitScreen) }
            )

            iconButton(
                "fitWidth", "arrow.left.and.right",
                hint: "Fit Width (⌘2)",
                isActive: state.fitMode == .fitWidth && state.isAtFit,
                action: { actions.onSetFitMode(.fitWidth) }
            )

            iconButton(
                "fitHeight", "arrow.up.and.down",
                hint: "Fit Height (⌘3)",
                isActive: state.fitMode == .fitHeight && state.isAtFit,
                action: { actions.onSetFitMode(.fitHeight) }
            )

            iconButton(
                "zoomOut", "minus.magnifyingglass",
                hint: "Zoom Out (⌘−)",
                action: actions.onZoomOut
            )

            iconButton(
                "zoomIn", "plus.magnifyingglass",
                hint: "Zoom In (⌘+)",
                action: actions.onZoomIn
            )

            iconButton(
                "autoFit", state.autoFitOnResize ? "lock.open" : "lock.fill",
                hint: state.autoFitOnResize
                    ? "Lock view size (don't auto-fit on resize) (⌘L)"
                    : "Unlock view size (auto-fit on resize) (⌘L)",
                isActive: !state.autoFitOnResize,
                action: actions.onToggleAutoFit
            )
        }
    }

    /// `fitAndZoomGroup` folded into one menu for narrow windows.
    private var fitAndZoomMenu: some View {
        PanelyIconMenu(systemImage: "plus.magnifyingglass", accessibilityTitle: "Fit & Zoom") {
            menuItem("Fit to Screen", isSelected: state.fitMode == .fitScreen && state.isAtFit) {
                actions.onSetFitMode(.fitScreen)
            }
            menuItem("Fit to Width", isSelected: state.fitMode == .fitWidth && state.isAtFit) {
                actions.onSetFitMode(.fitWidth)
            }
            menuItem("Fit to Height", isSelected: state.fitMode == .fitHeight && state.isAtFit) {
                actions.onSetFitMode(.fitHeight)
            }

            Divider()

            Button("Zoom In", action: actions.onZoomIn)
            Button("Zoom Out", action: actions.onZoomOut)

            Divider()

            menuItem("Lock View Size", isSelected: !state.autoFitOnResize) {
                actions.onToggleAutoFit()
            }
        }
        .toolbarHint("fitAndZoomMenu", "Fit & Zoom", hovered: $hoveredHint)
    }

    private var bookmarkGroup: some View {
        Group {
            iconButton(
                "favorite", state.isBookFavorite ? "star.fill" : "star",
                hint: state.isBookFavorite ? "Remove from Favorites (⌘⇧D)" : "Add to Favorites (⌘⇧D)",
                isActive: state.isBookFavorite,
                isEnabled: state.hasSource,
                action: actions.onToggleFavorite
            )

            iconButton(
                "bookmark", state.isPageBookmarked ? "bookmark.fill" : "bookmark",
                hint: state.isPageBookmarked ? "Remove Page Bookmark (⌘D)" : "Bookmark Current Page (⌘D)",
                isActive: state.isPageBookmarked,
                isEnabled: state.hasSource,
                action: actions.onTogglePageBookmark
            )

            bookmarkMenu

            iconButton(
                "thumbnails", "square.stack",
                hint: state.thumbnailSidebarVisible
                    ? "Hide Thumbnails (⌃⌘P)"
                    : "Show Thumbnails (⌃⌘P)",
                isActive: state.thumbnailSidebarVisible,
                isEnabled: state.hasSource,
                action: actions.onToggleThumbnailSidebar
            )
        }
    }

    /// Every bookmark one click away: the open book's pages, stepping between
    /// them, and the bookmarks left in other books.
    private var bookmarkMenu: some View {
        PanelyIconMenu(
            systemImage: "list.bullet.rectangle",
            accessibilityTitle: "Bookmark List"
        ) {
            if state.pageBookmarks.isEmpty {
                Text("No Bookmarks in This Book")
            } else {
                ForEach(state.pageBookmarks) { bookmark in
                    Button {
                        actions.onJumpToBookmark(bookmark)
                    } label: {
                        Label(
                            "Page \(bookmark.pageIndex + 1)",
                            systemImage: state.visiblePageRange.contains(bookmark.pageIndex)
                                ? "bookmark.fill"
                                : "bookmark"
                        )
                    }
                }
            }

            Divider()

            Button("Previous Bookmark", action: actions.onPreviousBookmark)
                .disabled(!state.canGoPreviousBookmark)
            Button("Next Bookmark", action: actions.onNextBookmark)
                .disabled(!state.canGoNextBookmark)

            if !state.otherBookmarkedBooks.isEmpty {
                Divider()
                Menu("Other Books") {
                    ForEach(state.otherBookmarkedBooks) { book in
                        Menu(book.qualifiedTitle) {
                            ForEach(book.bookmarks) { bookmark in
                                Button("Page \(bookmark.pageIndex + 1)") {
                                    actions.onOpenBookmark(bookmark, book)
                                }
                            }
                        }
                    }
                }
            }

            Divider()

            Button("Remove All Bookmarks in This Book…", role: .destructive) {
                actions.onRemoveAllPageBookmarks()
            }
            .disabled(state.pageBookmarks.isEmpty)
        }
        .toolbarHint("bookmarkList", "Bookmark List", hovered: $hoveredHint)
    }

    @ViewBuilder
    private var navigationGroup: some View {
        if state.showVolumeNav {
            iconButton(
                "previousVolume", "chevron.backward.2",
                hint: "Previous Volume ([)",
                isEnabled: state.canGoPreviousVolume,
                action: actions.onPreviousVolume
            )
        }

        iconButton(
            "previousPage", "chevron.left",
            hint: "Previous Page (\(previousKeyHint))",
            action: actions.onPrev
        )

        iconButton(
            "nextPage", "chevron.right",
            hint: "Next Page (\(nextKeyHint) or Space)",
            action: actions.onNext
        )

        if state.showVolumeNav {
            iconButton(
                "nextVolume", "chevron.forward.2",
                hint: "Next Volume (])",
                isEnabled: state.canGoNextVolume,
                action: actions.onNextVolume
            )
        }
    }

    // MARK: - Building blocks

    private func iconButton(
        _ id: String,
        _ systemImage: String,
        hint: LocalizedStringKey,
        isActive: Bool = false,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        PanelyIconButton(
            systemImage: systemImage,
            isActive: isActive,
            accessibilityTitle: hint,
            action: action
        )
        .disabled(!isEnabled)
        // Outside `.disabled` so a disabled control still explains itself.
        .toolbarHint(id, hint, hovered: $hoveredHint)
    }

    /// A menu row with a checkmark when it is the current choice.
    private func menuItem(
        _ title: LocalizedStringKey,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Toggle(title, isOn: Binding(get: { isSelected }, set: { _ in action() }))
    }

    /// Places the hint bubble just below the hovered control, nudged
    /// sideways when needed so it never hangs off either end of the toolbar.
    private func hintOverlay(anchors: [String: Anchor<CGRect>]) -> some View {
        GeometryReader { proxy in
            if let hint = hoveredHint, let anchor = anchors[hint.id] {
                let target = proxy[anchor]
                ToolbarHintBubble(text: hint.text)
                    .fixedSize()
                    .alignmentGuide(.leading) { bubble in
                        let centered = target.midX - bubble.width / 2
                        let rightmost = max(0, proxy.size.width - bubble.width)
                        return -min(max(centered, 0), rightmost)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .offset(y: proxy.size.height + PanelySpacing.xs)
                    .transition(.opacity)
            }
        }
        .allowsHitTesting(false)
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

    private var directionHint: LocalizedStringKey {
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
        actions: PanelyToolbarActions(),
        previewHint: ToolbarHint(id: "layoutDouble", text: "Double Page (⌘⇧2)")
    )
    .padding(PanelySpacing.xl)
    .frame(width: 960, height: 120, alignment: .top)
    .background(PanelyColor.bgPrimary)
}

#Preview("Narrow") {
    PanelyToolbar(
        state: PanelyToolbarState(
            layout: .double,
            direction: .rightToLeft,
            fitMode: .fitScreen,
            sidebarPinned: true,
            showVolumeNav: true,
            canGoPreviousVolume: true,
            canGoNextVolume: true
        ),
        actions: PanelyToolbarActions()
    )
    .padding(PanelySpacing.md)
    .frame(width: 560, height: 120, alignment: .top)
    .background(PanelyColor.bgPrimary)
}
