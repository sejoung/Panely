import SwiftUI

struct ViewerContainer: View {
    var images: [NSImage] = []
    var direction: ReadingDirection = .leftToRight
    var fitMode: FitMode = .fitScreen
    var identity: String = ""

    @State private var zoom: CGFloat = 1
    @State private var gestureZoom: CGFloat = 1

    private let minZoom: CGFloat = 0.5
    private let maxZoom: CGFloat = 5.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                PanelyColor.bgPrimary
                    .ignoresSafeArea()

                if images.isEmpty {
                    emptyState
                } else {
                    zoomableContent(viewport: geo.size)
                }
            }
        }
        .onChange(of: identity) { _, _ in resetZoom() }
        .onChange(of: fitMode) { _, _ in resetZoom() }
    }

    private var orderedImages: [NSImage] {
        direction.isRTL ? images.reversed() : images
    }

    private func zoomableContent(viewport: CGSize) -> some View {
        ScrollView([.vertical, .horizontal], showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(orderedImages.indices, id: \.self) { idx in
                    let img = orderedImages[idx]
                    let size = imageDisplaySize(for: img, viewport: viewport)
                    Image(nsImage: img)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: size.width, height: size.height)
                }
            }
            .frame(
                minWidth: viewport.width,
                minHeight: viewport.height
            )
        }
        .gesture(
            MagnifyGesture()
                .onChanged { value in
                    gestureZoom = value.magnification
                }
                .onEnded { _ in
                    zoom = clamp(zoom * gestureZoom)
                    gestureZoom = 1
                }
        )
        .onTapGesture(count: 2) {
            zoom = abs(zoom - 1) < 0.01 ? 2 : 1
            gestureZoom = 1
        }
    }

    private func imageDisplaySize(for image: NSImage, viewport: CGSize) -> CGSize {
        let effectiveScale = baseScale(viewport: viewport) * zoom * gestureZoom
        return CGSize(
            width: image.size.width * effectiveScale,
            height: image.size.height * effectiveScale
        )
    }

    private func baseScale(viewport: CGSize) -> CGFloat {
        guard !images.isEmpty else { return 1 }
        let totalWidth = images.reduce(0) { $0 + $1.size.width }
        let maxHeight = images.map { $0.size.height }.max() ?? 1
        guard totalWidth > 0, maxHeight > 0 else { return 1 }

        switch fitMode {
        case .fitScreen:
            return min(viewport.width / totalWidth, viewport.height / maxHeight)
        case .fitWidth:
            return viewport.width / totalWidth
        }
    }

    private func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, minZoom), maxZoom)
    }

    private func resetZoom() {
        zoom = 1
        gestureZoom = 1
    }

    private var emptyState: some View {
        VStack(spacing: PanelySpacing.md) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(PanelyColor.textSecondary)
            Text("No image loaded")
                .font(PanelyTypography.body)
                .foregroundStyle(PanelyColor.textSecondary)
            Text("Open a folder or CBZ to start reading")
                .font(PanelyTypography.caption)
                .foregroundStyle(PanelyColor.textSecondary.opacity(0.7))
        }
    }
}

#Preview {
    ViewerContainer()
        .frame(width: 800, height: 600)
}
