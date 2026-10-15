import AppKit
import CoreGraphics
import Foundation
import Vision

/// Balloons found on one page by one unit of work, still untranslated.
nonisolated struct PageAnalysis: Sendable {
    let pageIndex: Int
    let imageSize: CGSize
    /// `translation == nil`; ids are assigned when merged into the page.
    let bubbles: [TranslatedBubble]
}

/// OCR side of the pipeline: turns a `TranslationUnit` into balloons per page
/// (text, position in page pixels, background tone). Text is grouped into
/// balloons with the help of `BalloonDetector`, which also tells real text
/// from artwork OCR misread. An actor so the decoded
/// pages it keeps between strip bands are touched by one task at a time.
///
/// Strip bands overlap and a tall page spans several bands, so the last few
/// decoded pages are kept rather than decoding a 20,000 px page once per band.
@available(macOS 26.0, *)
actor PageAnalyzer {
    private let pages: [ComicPage]
    private let language: TranslationLanguage
    private var decoded: [(index: Int, image: CGImage)] = []
    private static let decodedCacheSize = 4

    init(pages: [ComicPage], language: TranslationLanguage) {
        self.pages = pages
        self.language = language
    }

    func analyze(_ unit: TranslationUnit, plan: TranslationPlan) async throws -> [PageAnalysis] {
        if let band = unit.band, let layout = plan.layout {
            return try await analyzeBand(band, layout: layout)
        }
        guard let index = unit.pageIndices.first else { return [] }
        return [try await analyzePage(index)]
    }

    // MARK: - Page scope

    private func analyzePage(_ index: Int) async throws -> PageAnalysis {
        let image = try await decodedImage(index)
        let (regions, detections) = try await recognize(image)
        let drafts = BubbleGrouper.group(regions, language: language, detections: detections)
        let bubbles = makeBubbles(from: drafts, sampling: image) { $0 }
        return PageAnalysis(pageIndex: index, imageSize: CGSize(width: image.width, height: image.height), bubbles: bubbles)
    }

    // MARK: - Strip scope

    private func analyzeBand(_ band: StripBand, layout: StripLayout) async throws -> [PageAnalysis] {
        let image = try await renderBand(band, layout: layout)
        let (recognized, detections) = try await recognize(image)
        let regions = recognized
            .filter { OCRTiling.isWhole($0.rect, bandHeight: Int(band.height), isFirst: band.isFirst, isLast: band.isLast) }
        let drafts = BubbleGrouper.group(regions, language: language, detections: detections)
            .filter { band.ownedRange.contains($0.rect.midY + band.top) }

        var byPage: [Int: [TranslatedBubble]] = [:]
        for draft in drafts {
            let page = layout.page(containingY: draft.rect.midY + band.top)
            let pageRect = layout.pageRect(page)
            let bubbles = makeBubbles(from: [draft], sampling: image) { rect in
                // band coordinates → that page's own pixel coordinates
                rect.offsetBy(dx: -pageRect.minX, dy: band.top - pageRect.minY)
            }
            byPage[page, default: []].append(contentsOf: bubbles)
        }
        // Every page this band owns gets an entry, even without balloons, so
        // the page is known to exist when the merge runs.
        return layout.pages(intersecting: band.ownedRange).map { page in
            PageAnalysis(pageIndex: page, imageSize: layout.pageSizes[page], bubbles: byPage[page] ?? [])
        }
    }

    /// Draw the pages under `band` into one image, positioned exactly as the
    /// vertical layout shows them.
    private func renderBand(_ band: StripBand, layout: StripLayout) async throws -> CGImage {
        let width = Int(layout.width.rounded(.up))
        let height = Int(band.height.rounded(.up))
        guard width > 0, height > 0,
              let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
              ) else { throw ImageLoaderError.decodingFailed }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for index in layout.pages(intersecting: band.top..<(band.top + band.height)) {
            try Task.checkCancellation()
            let image = try await decodedImage(index)
            let rect = layout.pageRect(index)
            // CG's origin is bottom-left; band rows run top-down.
            let y = band.height - (rect.minY - band.top) - rect.height
            context.draw(image, in: CGRect(x: rect.minX, y: y, width: rect.width, height: rect.height))
        }
        guard let image = context.makeImage() else { throw ImageLoaderError.decodingFailed }
        return image
    }

    // MARK: - Shared

    /// The text on `image` and the balloons around it, found side by side —
    /// detection (~0.1 s) finishes well within OCR (~3 s). `nil` detections
    /// when the detector can't run: the text is then grouped by its layout.
    private func recognize(_ image: CGImage) async throws -> ([TextRegion], [DetectedRegion]?) {
        async let detections = BalloonDetector.shared.detect(image)
        let regions = try await PageTextRecognizer(language: language).recognize(image)
        return (regions, await detections)
    }

    private func makeBubbles(
        from drafts: [BubbleDraft],
        sampling image: CGImage,
        toPageCoordinates: (CGRect) -> CGRect
    ) -> [TranslatedBubble] {
        drafts
            // Sound effects stay as drawn — see `SoundEffectClassifier`.
            .filter { !SoundEffectClassifier.isSoundEffect($0.source, language: language) }
            .map { draft in
                let padding = draft.glyphSize * 0.3
                return TranslatedBubble(
                    id: 0,
                    rect: toPageCoordinates(draft.rect),
                    glyphSize: draft.glyphSize,
                    isVertical: draft.isVertical,
                    source: draft.source,
                    translation: nil,
                    background: BubbleBackgroundSampler.sample(image, in: draft.rect.insetBy(dx: -padding, dy: -padding))
                )
            }
    }

    private func decodedImage(_ index: Int) async throws -> CGImage {
        if let hit = decoded.first(where: { $0.index == index }) { return hit.image }
        let image = try await ImageLoader.load(pages[index])
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ImageLoaderError.decodingFailed
        }
        decoded.append((index, cgImage))
        if decoded.count > Self.decodedCacheSize { decoded.removeFirst() }
        return cgImage
    }
}

/// Finds which language a book is in by reading a few pages with every
/// candidate language enabled. Runs once per series (the result is
/// remembered), since enabling all languages loads several OCR models.
@available(macOS 26.0, *)
nonisolated enum TranslationLanguageDetector {
    /// Pages tried, starting from the one being read — slices of a webtoon
    /// are often blank.
    static let maxPages = 6

    static func detect(in pages: [ComicPage], startingAt start: Int) async -> TranslationLanguage? {
        guard !pages.isEmpty else { return nil }
        var text = ""
        for index in TranslationController.translationOrder(count: pages.count, startingAt: start).prefix(maxPages) {
            if Task.isCancelled { return nil }
            guard let image = try? await ImageLoader.load(pages[index]),
                  let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { continue }
            var request = RecognizeDocumentsRequest()
            request.textRecognitionOptions.recognitionLanguages = TranslationLanguage.allCases.map(\.localeLanguage)
            request.textRecognitionOptions.automaticallyDetectLanguage = true
            // Only the start of a tall strip: enough text to tell, a fraction of the work.
            let probe = cgImage.height > cgImage.width * 3
                ? cgImage.cropping(to: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.width * 3)) ?? cgImage
                : cgImage
            guard let observations = try? await request.perform(on: probe) else { continue }
            text += observations.flatMap { $0.document.paragraphs.map(\.transcript) }.joined(separator: " ")
            if let language = TranslationLanguageClassifier.classify(text), text.count >= 12 {
                return language
            }
        }
        return TranslationLanguageClassifier.classify(text)
    }
}
