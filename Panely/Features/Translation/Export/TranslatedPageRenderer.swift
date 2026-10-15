import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Burns a page's translations into the page image, for export — the same
/// patches and text the overlay draws on screen, at the image's own pixels.
nonisolated enum TranslatedPageRenderer {
    /// A balloon to paint and the patch it covers, in the page's pixels. The
    /// patch is given separately because a strip balloon can start on the page
    /// above (see `bubbles(for:in:)`).
    struct Placed {
        let bubble: TranslatedBubble
        let patch: CGRect
    }

    /// The balloons drawn on page `index`: its own, plus — in strip scope,
    /// where a balloon can run past the bottom of its page — the part of a
    /// balloon from the page above that reaches into this one. Only balloons
    /// with a translation to show.
    static func bubbles(
        for index: Int,
        in pages: [TranslatedPage?],
        scope: TranslationScope
    ) -> [Placed] {
        guard pages.indices.contains(index), let page = pages[index] else {
            return carried(into: index, in: pages, scope: scope)
        }
        // Laid out as on screen: balloons drawn together come as one.
        let own = TranslationOverlayLayout.layout(for: page).drawn.map { Placed(bubble: $0.bubble, patch: $0.patch) }
        return own + carried(into: index, in: pages, scope: scope)
    }

    private static func carried(into index: Int, in pages: [TranslatedPage?], scope: TranslationScope) -> [Placed] {
        guard scope == .strip, index > 0, pages.indices.contains(index), let above = pages[index - 1] else { return [] }
        // Strip pages are centred on the widest one, so a page's x shifts by
        // half the width difference (none known for a page with no results).
        let dx = pages[index].map { ($0.imageWidth - above.imageWidth) / 2 } ?? 0
        return TranslationOverlayLayout.layout(for: above).drawn.compactMap { bubble, patch in
            guard patch.maxY > above.imageHeight else { return nil }
            return Placed(bubble: bubble, patch: patch.offsetBy(dx: dx, dy: -above.imageHeight))
        }
    }

    /// `image` with `bubbles` painted over it. `pageSize` is the size the
    /// translation was made at (normally the image's own); the drawing scales
    /// if the image differs.
    static func render(_ image: CGImage, bubbles: [Placed], pageSize: CGSize) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // Top-left origin in page pixels, like the overlay.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        if pageSize.width > 0, pageSize.height > 0 {
            context.scaleBy(x: CGFloat(width) / pageSize.width, y: CGFloat(height) / pageSize.height)
        }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        for placed in bubbles {
            guard let translation = placed.bubble.translation else { continue }
            TranslationPatchPainter.draw(
                translation,
                background: placed.bubble.background,
                glyph: CGFloat(placed.bubble.glyphSize),
                in: placed.patch
            )
        }
        NSGraphicsContext.current = previous
        return context.makeImage()
    }

    /// Encodes `image` for the archive: PNG stays PNG (line art, no new
    /// artefacts), everything else becomes a high-quality JPEG.
    static func encode(_ image: CGImage, asPNG: Bool) -> Data? {
        let data = NSMutableData()
        let type = asPNG ? UTType.png : UTType.jpeg
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
        let properties: [CFString: Any] = asPNG ? [:] : [kCGImageDestinationLossyCompressionQuality: 0.92]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
