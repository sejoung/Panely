import CoreGraphics
import CoreML
import Foundation
import Vision

/// A speech balloon or a block of text the detector found, in image pixels
/// (top-left origin).
nonisolated struct DetectedRegion: Equatable, Sendable {
    enum Kind: Int, Sendable {
        /// A balloon's outline.
        case balloon = 0
        /// The text inside a balloon.
        case textInBalloon = 1
        /// Text outside balloons — captions, signs, sound effects.
        case freeText = 2
    }

    let kind: Kind
    var rect: CGRect
    let score: Float
}

/// Finds speech balloons and text on a page with a detector trained on comics
/// (`Resources/ComicTextDetector.mlpackage`, built by
/// `scripts/convert-text-detector.py` from ogkalu/comic-text-and-bubble-detector,
/// Apache-2.0). `BubbleGrouper` uses what it finds to tell which OCR lines
/// share a balloon, and which "text" is really artwork.
///
/// Runs on the GPU: the Neural Engine's float16 math drifts on this model
/// (boxes ~13% off), the GPU matches the original (measured). ~70 ms a page.
actor BalloonDetector {
    static let shared = BalloonDetector()

    private var model: MLModel?
    private var unavailable = false

    /// What's on `image`, or `nil` when the model can't run (then the caller
    /// groups text without it).
    func detect(_ image: CGImage) async -> [DetectedRegion]? {
        guard let model = loadModel() else { return nil }
        let chunks = BalloonDetection.chunks(width: image.width, height: image.height)
        var found: [DetectedRegion] = []
        do {
            for (index, chunk) in chunks.enumerated() {
                try Task.checkCancellation()
                let rect = CGRect(x: 0, y: chunk.top, width: image.width, height: chunk.height)
                guard let crop = chunks.count == 1 ? image : image.cropping(to: rect) else { continue }
                for var region in try await detectWhole(crop, model: model)
                where OCRTiling.isWhole(region.rect, bandHeight: chunk.height, isFirst: index == 0, isLast: index == chunks.count - 1) {
                    region.rect.origin.y += CGFloat(chunk.top)
                    found.append(region)
                }
            }
        } catch {
            if !(error is CancellationError) {
                AppLog.error(.reader, "Balloon detection failed", metadata: ["error": "\(error)"])
            }
            return nil
        }
        return chunks.count > 1 ? BalloonDetection.deduplicate(found) : found
    }

    private func detectWhole(_ image: CGImage, model: MLModel) async throws -> [DetectedRegion] {
        guard let constraint = model.modelDescription.inputDescriptionsByName["image"]?.imageConstraint else { return [] }
        // Stretched to the square input, as the model was trained.
        let input = try MLFeatureValue(
            cgImage: image,
            constraint: constraint,
            options: [.cropAndScale: VNImageCropAndScaleOption.scaleFill.rawValue]
        )
        let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": input]))
        guard let scores = output.featureValue(for: "scores")?.multiArrayValue,
              let boxes = output.featureValue(for: "boxes")?.multiArrayValue
        else { return [] }
        return BalloonDetection.decode(
            scores: (0..<scores.count).map { scores[$0].floatValue },
            boxes: (0..<boxes.count).map { boxes[$0].floatValue },
            imageSize: CGSize(width: image.width, height: image.height)
        )
    }

    private func loadModel() -> MLModel? {
        if let model { return model }
        guard !unavailable else { return nil }
        guard let url = Bundle.main.url(forResource: "ComicTextDetector", withExtension: "mlmodelc") else {
            unavailable = true
            AppLog.error(.reader, "Balloon detector missing from the app bundle")
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuAndGPU
        do {
            model = try MLModel(contentsOf: url, configuration: configuration)
        } catch {
            unavailable = true
            AppLog.error(.reader, "Balloon detector failed to load", metadata: ["error": "\(error)"])
        }
        return model
    }
}

/// The detector's arithmetic, apart from Core ML so it can be tested.
nonisolated enum BalloonDetection {
    /// Below this the detector isn't sure enough to group text by.
    static let threshold: Float = 0.4

    /// Regions from the model's outputs: per-query class probabilities
    /// (queries × 3) and boxes (queries × 4: cx, cy, w, h in 0–1), most
    /// confident first. A query can name more than one class.
    static func decode(scores: [Float], boxes: [Float], imageSize: CGSize, threshold: Float = threshold) -> [DetectedRegion] {
        let classes = 3
        let queries = min(scores.count / classes, boxes.count / 4)
        var found: [DetectedRegion] = []
        for query in 0..<queries {
            for label in 0..<classes {
                let score = scores[query * classes + label]
                guard score >= threshold, let kind = DetectedRegion.Kind(rawValue: label) else { continue }
                let cx = CGFloat(boxes[query * 4]), cy = CGFloat(boxes[query * 4 + 1])
                let w = CGFloat(boxes[query * 4 + 2]), h = CGFloat(boxes[query * 4 + 3])
                let rect = CGRect(
                    x: (cx - w / 2) * imageSize.width,
                    y: (cy - h / 2) * imageSize.height,
                    width: w * imageSize.width,
                    height: h * imageSize.height
                )
                found.append(DetectedRegion(kind: kind, rect: rect, score: score))
            }
        }
        return found.sorted { $0.score > $1.score }
    }

    /// Strips taller than about one and a half screens are detected in
    /// overlapping chunks: squeezed whole into the square input, their
    /// balloons would shrink to a few pixels (the model was trained on strips
    /// cut the same way).
    static func chunks(width: Int, height: Int) -> [OCRTiling.Tile] {
        guard width > 0, height > 0 else { return [] }
        let chunkHeight = max(width * 3 / 2, 640)
        guard height > chunkHeight * 4 / 3 else { return [OCRTiling.Tile(top: 0, height: height)] }
        return OCRTiling.tiles(forHeight: height, tileHeight: chunkHeight, overlap: chunkHeight / 3)
    }

    /// The same region seen by two overlapping chunks, kept once — the more
    /// confident one.
    static func deduplicate(_ regions: [DetectedRegion]) -> [DetectedRegion] {
        var kept: [DetectedRegion] = []
        for region in regions.sorted(by: { $0.score > $1.score }) {
            let duplicate = kept.contains { $0.kind == region.kind && OCRTiling.overlapFraction($0.rect, region.rect) > 0.5 }
            if !duplicate { kept.append(region) }
        }
        return kept
    }
}
