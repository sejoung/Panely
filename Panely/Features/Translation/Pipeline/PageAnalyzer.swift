import AppKit
import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Reads a unit's balloons. `PageAnalyzer` in the app; tests hand balloons
/// to a job directly.
nonisolated protocol PageAnalyzing: Sendable {
    func analyze(_ unit: TranslationUnit, plan: TranslationPlan) async throws -> [PageAnalysis]
}

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
/// decoded pages are kept rather than decoding a 20,000 px page once per band
/// — and bands read side by side (fast mode) share a page being decoded.
/// Page scope reads each page once, so it keeps none.
@available(macOS 26.0, *)
actor PageAnalyzer: PageAnalyzing {
    private let pages: [ComicPage]
    private let language: TranslationLanguage
    private var decoded: [(index: Int, image: CGImage)] = []
    private var decoding: [Int: Task<CGImage, any Error>] = [:]
    private static let decodedCacheSize = 4
    /// Also bounded by size: four 20,000 px slices are ~1 GB decoded.
    private static let decodedCachePixels = 48_000_000
    /// Second looks read side by side, a few at a time — enough to keep up
    /// with fast translation without crowding out the pages' own OCR.
    private static let concurrentRereads = 2

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
        let image = try await Self.decode(pages[index])
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
            let image = try await stripPage(index)
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
    /// detection (~0.1 s) finishes well within OCR (~3 s) — plus whatever a
    /// second look at text boxes OCR left empty reads (`MissedText`). `nil`
    /// detections when the detector can't run: the text is then grouped by
    /// its layout.
    private func recognize(_ image: CGImage) async throws -> ([TextRegion], [DetectedRegion]?) {
        async let detections = BalloonDetector.shared.detect(image)
        let regions = try await PageTextRecognizer(language: language).recognize(image)
        guard let found = await detections else { return (regions, nil) }
        return (regions + (try await reread(MissedText.boxesToReread(found, regions: regions), in: image)), found)
    }

    /// Each box cut out, enlarged and read on its own — a few at once, the
    /// results kept in the boxes' order.
    private func reread(_ boxes: [DetectedRegion], in image: CGImage) async throws -> [TextRegion] {
        let language = language
        var results = [[TextRegion]](repeating: [], count: boxes.count)
        try await withThrowingTaskGroup(of: (Int, [TextRegion]).self) { group in
            for (index, box) in boxes.enumerated() {
                if index >= Self.concurrentRereads, let (done, regions) = try await group.next() {
                    results[done] = regions
                }
                group.addTask { (index, try await Self.reread(box, in: image, language: language)) }
            }
            for try await (done, regions) in group {
                results[done] = regions
            }
        }
        let found = results.flatMap { $0 }
        if !found.isEmpty {
            AppLog.debug(.reader, "Second look read missed text", metadata: ["boxes": "\(boxes.count)", "regions": "\(found.count)"])
        }
        return found
    }

    private static func reread(_ box: DetectedRegion, in image: CGImage, language: TranslationLanguage) async throws -> [TextRegion] {
        try Task.checkCancellation()
        let crop = MissedText.cropRect(for: box.rect, in: CGSize(width: image.width, height: image.height))
        let scale = MissedText.scale(for: crop)
        guard crop.width >= 4, crop.height >= 4, let enlarged = enlarge(image, crop: crop, scale: scale) else { return [] }
        return try await PageTextRecognizer(language: language).recognize(enlarged)
            .filter { !MissedText.isNoise($0.text) }
            .map { MissedText.mapBack($0, crop: crop, scale: scale) }
    }

    private static func enlarge(_ image: CGImage, crop: CGRect, scale: CGFloat) -> CGImage? {
        guard let cut = image.cropping(to: crop) else { return nil }
        let width = Int(crop.width * scale), height = Int(crop.height * scale)
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(cut, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
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
                let textArea = draft.rect.insetBy(dx: -padding, dy: -padding)
                let background = BubbleBackgroundSampler.sample(image, in: textArea)
                return TranslatedBubble(
                    id: 0,
                    rect: toPageCoordinates(draft.rect),
                    glyphSize: draft.glyphSize,
                    isVertical: draft.isVertical,
                    source: draft.source,
                    translation: nil,
                    background: background,
                    balloonRect: draft.balloonRect.flatMap { balloon in
                        roomIsEmpty(in: balloon, around: textArea, background: background, image: image) ? toPageCoordinates(balloon) : nil
                    }
                )
            }
    }

    /// Share of ink above which the room inside a balloon (beyond its text)
    /// isn't empty. Measured: an empty balloon interior 0–1.3%, a balloon
    /// with a line OCR didn't read 9%.
    static let maxInkInBalloonRoom = 0.03

    /// Whether the translation may spread into the balloon's room: only a
    /// flat-toned balloon with nothing else in it. A line OCR missed would
    /// otherwise be painted over, untranslated.
    private func roomIsEmpty(in balloon: CGRect, around textArea: CGRect, background: BubbleBackground, image: CGImage) -> Bool {
        guard background.isUniform else { return false }
        let room = TranslationOverlayLayout.roomInside(balloon)
        return BubbleBackgroundSampler.inkShare(image, in: room, excluding: textArea, background: background) < Self.maxInkInBalloonRoom
    }

    /// A page under a strip band: kept for the bands after it, and decoded
    /// once when bands read side by side both need it.
    private func stripPage(_ index: Int) async throws -> CGImage {
        if let hit = decoded.first(where: { $0.index == index }) { return hit.image }
        if let inFlight = decoding[index] { return try await inFlight.value }
        let page = pages[index]
        let task = Task { try await Self.decode(page) }
        decoding[index] = task
        defer { decoding[index] = nil }
        let image = try await task.value
        decoded.append((index, image))
        var pixels = decoded.reduce(0) { $0 + $1.image.width * $1.image.height }
        while decoded.count > Self.decodedCacheSize || (decoded.count > 1 && pixels > Self.decodedCachePixels) {
            let dropped = decoded.removeFirst()
            pixels -= dropped.image.width * dropped.image.height
        }
        return image
    }

    /// A page decoded for analysis. Like `ImageLoader.load`, but at utility
    /// priority: that decodes the pages on screen at user-initiated, and a
    /// job's OCR running in the background shouldn't compete with them.
    nonisolated static func decode(_ page: ComicPage) async throws -> CGImage {
        let data: Data?
        switch page.source {
        case .file:
            data = nil
        case let .archiveEntry(reader, path):
            data = try await reader.loadData(at: path)
        }
        return try await Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let source: CGImageSource? = switch page.source {
            case let .file(url): CGImageSourceCreateWithURL(url as CFURL, nil)
            case .archiveEntry: data.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }
            }
            // Decoded here, not on first use (see `ImageLoader`).
            let options = [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
            guard let source, let image = CGImageSourceCreateImageAtIndex(source, 0, options) else {
                throw ImageLoaderError.decodingFailed
            }
            return image
        }.value
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
            guard let cgImage = try? await PageAnalyzer.decode(pages[index]) else { continue }
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
