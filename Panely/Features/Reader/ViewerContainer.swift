import SwiftUI

struct ViewerContainer: View {
    var images: [NSImage] = []
    var direction: ReadingDirection = .leftToRight

    var body: some View {
        ZStack {
            PanelyColor.bgPrimary

            if images.isEmpty {
                emptyState
            } else {
                HStack(spacing: 0) {
                    ForEach(orderedImages.indices, id: \.self) { idx in
                        Image(nsImage: orderedImages[idx])
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    }
                }
            }
        }
    }

    private var orderedImages: [NSImage] {
        direction.isRTL ? images.reversed() : images
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
