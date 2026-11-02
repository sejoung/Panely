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
nonisolated struct VisionPageTextRecognizer {
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
                // Vision rects are normalized with a bottom-left origin.
                let box = paragraph.boundingRegion.boundingBox.cgRect
                let rect = CGRect(
                    x: box.minX * width,
                    y: (1 - box.maxY) * height,
                    width: box.width * width,
                    height: box.height * height
                )
                // Vision calls short horizontal Korean lines in narrow
                // balloons top-to-bottom (a third of a Korean volume's
                // balloons), which keeps them from merging with the rest of
                // their balloon. Outside Japanese and Chinese, only text that
                // is clearly taller than wide (a vertical sign) is vertical.
                let isVertical = lines.contains { $0.textDirection == .topToBottom }
                    && (language.isWrittenVertically || rect.height > rect.width * 1.5)
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

/// Production selects comic OCR when its pack is present. Explicit engines
/// support reproducible comparisons without silently timing a fallback.
@available(macOS 26.0, *)
nonisolated struct PageTextRecognizer {
    enum Backend: String, Sendable { case automatic, comic, vision }
    let language: TranslationLanguage
    var backend: Backend = .automatic

    static var configuredBackend: Backend {
        Backend(rawValue: ProcessInfo.processInfo.environment["PANELY_OCR_ENGINE"] ?? "") ?? .automatic
    }

    func recognize(_ image: CGImage) async throws -> [TextRegion] {
        let selected = backend == .automatic ? Self.configuredBackend : backend
        if selected != .vision, ComicOCREngine.shared.isReady(for: language) {
            do { return try await ComicOCREngine.shared.recognize(image, language: language, detections: nil) }
            catch {
                try Task.checkCancellation()
                if selected == .comic { throw error }
                AppLog.error(.reader, "Comic OCR failed; using Vision", metadata: ["error": "\(error)"])
            }
        } else if selected == .comic { throw TranslationModelError.notInstalled }
        return try await VisionPageTextRecognizer(language: language).recognize(image)
    }
}
