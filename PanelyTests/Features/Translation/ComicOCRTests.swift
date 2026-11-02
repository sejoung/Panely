import AppKit
import Foundation
import Testing
@testable import Panely

struct ComicOCRDecodingTests {
    @Test func mangaStopsAtEndAndNormalizesWidth() {
        let vocab = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]", "こん", "にちは", " A1…", "余分"]
        #expect(ComicOCRDecoding.manga([2, 5, 6, 7, 3, 8], vocabulary: vocab) == "こんにちはＡ１．．．")
    }

    @Test func ctcKeepsRepeatsSeparatedByBlankAndDecodesTransposed() throws {
        let values: [Float] = [0, 1, 0, 0, 1, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
        let result = try ComicOCRDecoding.ctc(values, shape: [1, 5, 3], dictionary: ["a", "b"])
        #expect(result.text == "aab")
        #expect(result.confidence == 1)
        let transposed = (0..<3).flatMap { c in (0..<5).map { t in values[t * 3 + c] } }
        #expect(try ComicOCRDecoding.ctc(transposed, shape: [1, 3, 5], dictionary: ["a", "b"]).text == "aab")
    }

    @Test func longEnglishLinesAreNotMistakenForTransposedOutput() throws {
        let values: [Float] = (0..<10).flatMap { _ in [Float(0), 1, 0] }
        #expect(try ComicOCRDecoding.ctc(values, shape: [1, 10, 3], dictionary: ["a", "b"]).text == "a")
        #expect(throws: ComicOCRError.self) { try ComicOCRDecoding.ctc([], shape: [1, 10, 3], dictionary: ["a", "b"]) }
    }

    @Test func dbRejectsNoiseAndClipsExpandedBoxes() throws {
        var map = [Float](repeating: 0, count: 20 * 20)
        for y in 0..<4 { for x in 0..<8 { map[y * 20 + x] = 0.9 } }
        map[19 * 20 + 19] = 1
        let boxes = try ComicOCRDecoding.boxes(map, width: 20, height: 20)
        #expect(boxes.count == 1)
        #expect(boxes[0].minX == 0 && boxes[0].minY == 0)
        #expect(boxes[0].maxX <= 20 && boxes[0].maxY <= 20)
        let size = ComicOCRDecoding.detectorSize(width: 720, height: 20000)
        #expect(size.width % 32 == 0 && size.height % 32 == 0)
        #expect(size.height <= 2400)
    }

    @Test func comicBoxesRejectBalloonsAndDeduplicateAcrossClasses() {
        let box = CGRect(x: -2, y: 10, width: 102, height: 40)
        let detections = [DetectedRegion(kind: .balloon, rect: box, score: 1),
                          DetectedRegion(kind: .textInBalloon, rect: box, score: 0.9),
                          DetectedRegion(kind: .freeText, rect: box, score: 0.8),
                          DetectedRegion(kind: .freeText, rect: CGRect(x: 150, y: 80, width: 10, height: 10), score: 0.4)]
        #expect(ComicOCRDecoding.textBoxes(detections, bounds: CGRect(x: 0, y: 0, width: 200, height: 200)) == [CGRect(x: 0, y: 10, width: 100, height: 40)])
    }

    @Test func progressiveBatchesKeepEveryBalloonWhole() {
        let upper = CGRect(x: 0, y: 0, width: 200, height: 300)
        let lower = upper.offsetBy(dx: 0, dy: 400)
        let lines = (0..<5).map { CGRect(x: 20 + $0 * 30, y: 20, width: 20, height: 180) }
            + (0..<5).map { CGRect(x: 20 + $0 * 30, y: 420, width: 20, height: 180) }
        let batches = ComicOCRDecoding.batches(lines, detections: [DetectedRegion(kind: .balloon, rect: upper, score: 1),
            DetectedRegion(kind: .balloon, rect: lower, score: 1)])
        #expect(batches.count == 2)
        #expect(batches[0] == Array(lines.prefix(5)))
        #expect(batches[1] == Array(lines.suffix(5)))
    }

    @Test func inputUsesBGRPaddingAndGrayscaleAndRotatesWithoutMirroring() throws {
        let pixels = OCRPixels(width: 2, height: 1, rgba: [255, 0, 0, 255, 0, 0, 255, 255])
        #expect(pixels.normalized(paddedWidth: 3) == [-1, 1, 0, -1, -1, 0, 1, -1, 0])
        let gray = pixels.normalized(grayscale: true)
        #expect(gray[0] == gray[2] && gray[2] == gray[4])
        let rotated = pixels.rotatedCounterClockwise()
        #expect(rotated.width == 1 && rotated.height == 2)
        #expect(Array(rotated.rgba.prefix(4)) == [0, 0, 255, 255])
        let resized = try pixels.resized(width: 2, height: 1)
        #expect(resized.rgba == pixels.rgba)
    }

    @Test func cancellationDoesNotBecomeAFallbackOrEmptyResult() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try ComicOCRDecoding.boxes([Float](repeating: 1, count: 10000), width: 100, height: 100)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Explicit opt-in: downloads the pinned OCR pack into a test cache, then runs
/// actual ONNX inference. Ordinary tests never download or substitute fake OCR.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PANELY_TEST_COMIC_OCR"] == "1"))
struct ComicOCRIntegrationTests {
    private static let prepared = Task<URL, any Error> {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("panely-ocr-test-models")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for model in ComicOCRModels.files {
            let files = TranslationModelFiles(root: root, model: model)
            if files.isInstalled { continue }
            let staging = root.appendingPathComponent(UUID().uuidString + ".download")
            defer { try? FileManager.default.removeItem(at: staging) }
            try await URLSessionModelDownloader().download(from: model.url, to: staging) { _, _ in }
            try files.install(downloadedFile: staging)
        }
        return root
    }

    @MainActor
    private func page(_ text: String, vertical: Bool = false) throws -> CGImage {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 1000, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 1000).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black]
        if vertical {
            for (i, character) in text.enumerated() {
                (String(character) as NSString).draw(at: NSPoint(x: 400, y: 850 - CGFloat(i) * 68), withAttributes: attributes)
            }
        } else { (text as NSString).draw(at: NSPoint(x: 80, y: 700), withAttributes: attributes) }
        return try #require(rep.cgImage)
    }

    @Test func actualModelsReadFourLanguagesAndVerticalJapanese() async throws {
        let engine = ComicOCREngine(root: try await Self.prepared.value)
        for (language, text, needle, vertical) in [(TranslationLanguage.japanese, "こんにちは", "こんにちは", false),
            (.japanese, "ありがとう", "ありがとう", true), (.korean, "안녕하세요", "안녕", false),
            (.chineseSimplified, "你好世界", "你好", false), (.english, "Hello world", "hello", false)] {
            let image = try await page(text, vertical: vertical)
            let start = ContinuousClock.now
            let regions = try await engine.recognize(image, language: language, detections: nil)
            let result = regions.map(\.text).joined()
            print("OCRBENCH engine=comic language=\(language.rawValue) vertical=\(vertical) time=\(start.duration(to: .now)) text=\(result)")
            #expect(result.lowercased().contains(needle), "\(language): \(result)")
            if #available(macOS 26.0, *), ProcessInfo.processInfo.environment["PANELY_COMPARE_VISION"] == "1" {
                let start = ContinuousClock.now
                let old = try await VisionPageTextRecognizer(language: language).recognize(image)
                print("OCRBENCH engine=vision language=\(language.rawValue) vertical=\(vertical) time=\(start.duration(to: .now)) text=\(old.map(\.text).joined())")
            }
        }
        let blank = try await page("")
        #expect(try await engine.recognize(blank, language: .japanese, detections: []).isEmpty)
        await engine.unload()
    }

    @Test func languageEvidenceUsesConfidenceAcrossReaders() async throws {
        let engine = ComicOCREngine(root: try await Self.prepared.value)
        for (language, text) in [(TranslationLanguage.japanese, "こんにちは今日はいい天気"), (.korean, "안녕하세요 오늘은 좋은 날"), (.english, "Hello world good morning")] {
            let evidence = try await engine.languageEvidence(page(text))
            #expect(TranslationLanguageClassifier.classify(evidence) == language, "\(language): \(evidence)")
        }
        await engine.unload()
    }
}
