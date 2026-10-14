import CoreGraphics
import Foundation
import Vision

/// Finds the text on a page with Vision's document recognizer.
///
/// macOS 26's `RecognizeDocumentsRequest` is the first Vision request that
/// reads vertical (tategaki) text — the older `VNRecognizeTextRequest` returns
/// nothing for it — and it groups lines into paragraphs, which
/// `BubbleGrouper` builds balloons from. Tall strips are read band by band
/// (see `OCRTiling`).
@available(macOS 26.0, *)
nonisolated struct PageTextRecognizer {
    let language: TranslationLanguage

    func recognize(_ image: CGImage) async throws -> [TextRegion] {
        let tiles = OCRTiling.tiles(width: image.width, height: image.height)
        var found: [TextRegion] = []
        for (index, tile) in tiles.enumerated() {
            try Task.checkCancellation()
            let band = CGRect(x: 0, y: tile.top, width: image.width, height: tile.height)
            guard let crop = image.cropping(to: band) else { continue }
            for var region in try await recognizeBand(crop)
            where OCRTiling.isWhole(region.rect, bandHeight: tile.height, isFirst: index == 0, isLast: index == tiles.count - 1) {
                region.rect.origin.y += CGFloat(tile.top)
                found.append(region)
            }
        }
        return tiles.count > 1 ? OCRTiling.deduplicate(found) : found
    }

    private func recognizeBand(_ image: CGImage) async throws -> [TextRegion] {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.recognitionLanguages = [language.localeLanguage]
        request.textRecognitionOptions.useLanguageCorrection = true
        let width = CGFloat(image.width)
        let height = CGFloat(image.height)

        return try await request.perform(on: image).flatMap { observation in
            observation.document.paragraphs.compactMap { paragraph -> TextRegion? in
                let lines = paragraph.lines
                guard !lines.isEmpty else { return nil }
                let isVertical = lines.contains { $0.textDirection == .topToBottom }
                // Vision rects are normalized with a bottom-left origin.
                let box = paragraph.boundingRegion.boundingBox.cgRect
                let rect = CGRect(
                    x: box.minX * width,
                    y: (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                )
                let glyphSize = lines.map { line in
                    let lineBox = line.boundingBox.cgRect
                    return isVertical ? lineBox.width * width : lineBox.height * height
                }.min() ?? 0
                return TextRegion(
                    text: lines.map(\.transcript).joined(separator: "\n"),
                    rect: rect,
                    isVertical: isVertical,
                    glyphSize: glyphSize
                )
            }
        }
    }
}
