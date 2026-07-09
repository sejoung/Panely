import AppKit
import SwiftUI

struct ViewerContainer: View {
    var images: [NSImage] = []
    var direction: ReadingDirection = .leftToRight
    var fitMode: FitMode = .fitScreen
    var layout: PageLayout = .single
    var pageIndex: Int = 0
    /// True while a book is open (even mid-load when `images` is briefly empty).
    /// Keeps the AppKit scroller — and its coordinator's live zoom/scroll state
    /// — mounted across book switches instead of tearing it down every time the
    /// strip empties. Without this, switching books recreated the scroll view
    /// and discarded the magnification, breaking zoom carry-over.
    var hasSource: Bool = false
    var identity: String = ""
    var seriesIdentity: String = ""
    var onPageIndexChanged: (Int) -> Void = { _ in }
    var onVisibleRangeChanged: (Range<Int>) -> Void = { _ in }
    var autoFitOnResize: Bool = true
    var wheelPageTurn: Bool = true
    var onWheelPageTurn: (PageTurnDirection) -> Void = { _ in }
    var viewerController: ViewerController? = nil

    var body: some View {
        ZStack {
            PanelyColor.bgPrimary
                .ignoresSafeArea()

            if images.isEmpty && !hasSource {
                emptyState
            } else {
                AppKitImageScroller(
                    images: images,
                    direction: direction,
                    fitMode: fitMode,
                    layout: layout,
                    pageIndex: pageIndex,
                    identity: identity,
                    seriesIdentity: seriesIdentity,
                    onPageIndexChanged: onPageIndexChanged,
                    onVisibleRangeChanged: onVisibleRangeChanged,
                    autoFitOnResize: autoFitOnResize,
                    wheelPageTurn: wheelPageTurn,
                    onWheelPageTurn: onWheelPageTurn,
                    viewerController: viewerController
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: PanelySpacing.md) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(PanelyColor.textSecondary)
            Text("No image loaded")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textSecondary)
            Text("Open a folder, CBZ, or ZIP to start reading")
                .font(PanelyTypography.caption)
                .foregroundStyle(PanelyColor.textSecondary.opacity(0.7))
        }
    }
}

#Preview {
    ViewerContainer()
        .frame(width: 800, height: 600)
}
