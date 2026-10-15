import AppKit
import Foundation
@testable import Panely

/// Drawn-from-scratch manga pages with Japanese balloons, and their English
/// translations, for the translation screenshots. Like the rest of the
/// gallery nothing is loaded from outside, so there's no copyright exposure;
/// the translated version goes through the exporter's own renderer, so the
/// shots show exactly what the overlay and an export look like.
@MainActor
enum TranslationSnapshotContent {
    static let pageSize = CGSize(width: 800, height: 1200)

    /// A balloon on a sample page: vertical Japanese columns (right to left)
    /// inside an ellipse, or a horizontal caption box.
    struct Balloon {
        /// The balloon's outline, top-left origin.
        let frame: CGRect
        /// Vertical columns, read right to left; one entry for a caption.
        let columns: [String]
        let translation: String
        var isCaption = false
    }

    struct Page {
        let panels: [CGRect]
        let balloons: [Balloon]
        let hue: CGFloat
    }

    static let pages: [Page] = [
        Page(
            panels: [
                CGRect(x: 40, y: 40, width: 720, height: 520),
                CGRect(x: 40, y: 580, width: 350, height: 580),
                CGRect(x: 410, y: 580, width: 350, height: 580),
            ],
            balloons: [
                Balloon(frame: CGRect(x: 60, y: 62, width: 330, height: 70), columns: ["その朝、町は静かだった。"], translation: "That morning, the town was quiet.", isCaption: true),
                Balloon(frame: CGRect(x: 520, y: 90, width: 210, height: 300), columns: ["ここは", "どこ？"], translation: "Where am I?"),
                Balloon(frame: CGRect(x: 80, y: 620, width: 270, height: 330), columns: ["やっと", "目が", "覚めたね"], translation: "You're finally awake."),
                Balloon(frame: CGRect(x: 450, y: 630, width: 270, height: 330), columns: ["夢を", "見ていた", "気がする"], translation: "I feel like I was dreaming."),
            ],
            hue: 0.58
        ),
        Page(
            panels: [
                CGRect(x: 40, y: 40, width: 720, height: 560),
                CGRect(x: 40, y: 620, width: 720, height: 540),
            ],
            balloons: [
                Balloon(frame: CGRect(x: 90, y: 80, width: 220, height: 260), columns: ["行こう！"], translation: "Let's go!"),
                Balloon(frame: CGRect(x: 480, y: 150, width: 240, height: 300), columns: ["待って", "！"], translation: "Wait!"),
                Balloon(frame: CGRect(x: 420, y: 680, width: 300, height: 380), columns: ["置いて", "いかない", "で"], translation: "Don't leave me behind!"),
            ],
            hue: 0.08
        ),
    ]

    // MARK: - Drawing

    private static let fontSize: CGFloat = 38

    private static var font: NSFont {
        NSFont(name: "HiraginoSans-W6", size: fontSize) ?? .systemFont(ofSize: fontSize, weight: .semibold)
    }

    /// The page as drawn, before translation.
    static func original(_ page: Page) -> NSImage {
        let size = pageSize
        // Flipped (top-left origin, like the balloon frames) so text draws
        // upright — a flipping transform alone would mirror it.
        let image = NSImage(size: size, flipped: true) { _ in
            drawPage(page, size: size)
            return true
        }
        // Drawn once, now, rather than whenever the image is.
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        return NSImage(cgImage: cgImage, size: size)
    }

    private static func drawPage(_ page: Page, size: CGSize) {
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        for (index, panel) in page.panels.enumerated() {
            drawArt(in: panel, hue: page.hue + CGFloat(index) * 0.05, seed: index)
            NSColor.black.setStroke()
            let border = NSBezierPath(rect: panel)
            border.lineWidth = 5
            border.stroke()
        }
        for balloon in page.balloons {
            drawBalloon(balloon)
        }
    }

    /// A simple scene: sky, sun, hills and a few screentone dots.
    private static func drawArt(in panel: CGRect, hue: CGFloat, seed: Int) {
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(rect: panel).addClip()
        NSColor(hue: hue, saturation: 0.12, brightness: 0.97, alpha: 1).setFill()
        panel.fill()
        NSColor(hue: hue, saturation: 0.08, brightness: 0.88, alpha: 1).setFill()
        let sun = CGRect(x: panel.minX + panel.width * (seed.isMultiple(of: 2) ? 0.12 : 0.62), y: panel.minY + panel.height * 0.3, width: 120, height: 120)
        NSBezierPath(ovalIn: sun).fill()
        let hills = NSBezierPath()
        hills.move(to: CGPoint(x: panel.minX, y: panel.maxY))
        hills.line(to: CGPoint(x: panel.minX, y: panel.maxY - panel.height * 0.3))
        hills.curve(
            to: CGPoint(x: panel.maxX, y: panel.maxY - panel.height * 0.38),
            controlPoint1: CGPoint(x: panel.minX + panel.width * 0.35, y: panel.maxY - panel.height * 0.6),
            controlPoint2: CGPoint(x: panel.minX + panel.width * 0.65, y: panel.maxY - panel.height * 0.1)
        )
        hills.line(to: CGPoint(x: panel.maxX, y: panel.maxY))
        hills.close()
        NSColor(hue: hue, saturation: 0.18, brightness: 0.62, alpha: 1).setFill()
        hills.fill()
        NSColor.black.withAlphaComponent(0.12).setFill()
        var y = panel.maxY - panel.height * 0.22
        while y < panel.maxY {
            var x = panel.minX + 6
            while x < panel.maxX {
                NSBezierPath(ovalIn: CGRect(x: x, y: y, width: 4, height: 4)).fill()
                x += 12
            }
            y += 12
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBalloon(_ balloon: Balloon) {
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        if balloon.isCaption {
            NSColor(white: 0.97, alpha: 1).setFill()
            balloon.frame.fill()
            NSColor.black.setStroke()
            let box = NSBezierPath(rect: balloon.frame)
            box.lineWidth = 3
            box.stroke()
            let text = balloon.columns[0] as NSString
            let small: [NSAttributedString.Key: Any] = [.font: font.withSize(26), .foregroundColor: NSColor.black]
            let size = text.size(withAttributes: small)
            text.draw(at: CGPoint(x: balloon.frame.midX - size.width / 2, y: balloon.frame.midY - size.height / 2), withAttributes: small)
            return
        }
        NSColor.white.setFill()
        let outline = NSBezierPath(ovalIn: balloon.frame)
        outline.fill()
        NSColor.black.setStroke()
        outline.lineWidth = 4
        outline.stroke()
        let text = textBounds(balloon)
        for (column, line) in balloon.columns.enumerated() {
            // Right to left.
            let x = text.maxX - CGFloat(column + 1) * columnWidth
            for (row, character) in line.enumerated() {
                let glyph = String(character) as NSString
                let size = glyph.size(withAttributes: attributes)
                glyph.draw(
                    at: CGPoint(x: x + (columnWidth - size.width) / 2, y: text.minY + CGFloat(row) * lineHeight),
                    withAttributes: attributes
                )
            }
        }
    }

    private static var columnWidth: CGFloat { fontSize * 1.25 }
    private static var lineHeight: CGFloat { fontSize * 1.08 }

    /// Where the text sits in a balloon — what OCR would report.
    private static func textBounds(_ balloon: Balloon) -> CGRect {
        if balloon.isCaption {
            return balloon.frame.insetBy(dx: 12, dy: 14)
        }
        let rows = balloon.columns.map(\.count).max() ?? 0
        let width = CGFloat(balloon.columns.count) * columnWidth
        let height = CGFloat(rows) * lineHeight
        return CGRect(x: balloon.frame.midX - width / 2, y: balloon.frame.midY - height / 2, width: width, height: height)
    }

    // MARK: - Translation

    /// What the translation assist finds on `page`: its balloons and their
    /// translations, in page pixels.
    static func translated(_ page: Page) -> TranslatedPage {
        TranslatedPage(
            imageWidth: pageSize.width,
            imageHeight: pageSize.height,
            bubbles: page.balloons.enumerated().map { index, balloon in
                TranslatedBubble(
                    id: index,
                    rect: textBounds(balloon),
                    glyphSize: balloon.isCaption ? 26 : fontSize,
                    isVertical: !balloon.isCaption,
                    source: balloon.columns.joined(),
                    translation: balloon.translation,
                    background: balloon.isCaption
                        ? BubbleBackground(red: 0.97, green: 0.97, blue: 0.97, isUniform: true)
                        : .white,
                    balloonRect: balloon.isCaption ? nil : balloon.frame
                )
            }
        )
    }

    /// The page as the reader shows it with the translation on.
    static func translatedImage(_ page: Page) -> NSImage {
        let original = original(page)
        guard let cgImage = original.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return original }
        let result = translated(page)
        let placed = TranslatedPageRenderer.bubbles(for: 0, in: [result], scope: .page)
        guard let rendered = TranslatedPageRenderer.render(cgImage, bubbles: placed, pageSize: pageSize) else { return original }
        return NSImage(cgImage: rendered, size: pageSize)
    }

    // MARK: - View models

    /// A loaded double-page book translated into English: the toolbar shows
    /// the translate button on and "English ▾".
    static func translatedViewModel() async throws -> ReaderViewModel {
        AppLocalization.shared.apply(.english)
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            direction: .rightToLeft,
            sidebarPinned: false,
            pageIndex: 0,
            pageCount: 24
        )
        vm.appLanguage = .english
        vm.translationTargetLanguage = .english
        vm.seriesPreferences.setTranslationSource(.japanese, forSeries: vm.seriesIdentity)
        for (index, page) in pages.enumerated() {
            try vm.translationManager.store.save(
                translated(page),
                key: TranslationStore.key(pageID: vm.source.pages[index].id, from: .japanese, to: .english)
            )
        }
        vm.translationEnabled = true
        try await waitUntil { vm.translation.completedPageCount >= pages.count }
        vm.imageLoader.currentImages = pages.map(translatedImage)
        return vm
    }
}
