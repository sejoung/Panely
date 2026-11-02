import CoreGraphics
import Foundation
import OnnxRuntimeBindings

/// Serializes ONNX sessions off the main actor. Sessions are shared by all books
/// and released after two idle minutes. Vision is only used by the caller on failure.
actor ComicOCREngine {
    static let shared = ComicOCREngine()
    let root: URL
    private var environment: ORTEnv?
    private var sessions: [String: ORTSession] = [:]
    private var dictionaries: [String: [String]] = [:]
    private var idleTask: Task<Void, Never>?

    init(root: URL = TranslationModelFiles.defaultRoot()) { self.root = root }

    nonisolated func isReady(for language: TranslationLanguage) -> Bool {
        ComicOCRModels.isInstalled(at: root, manga: false)
            && (language != .japanese || ComicOCRModels.isInstalled(at: root, manga: true))
    }

    func recognize(_ image: CGImage, language: TranslationLanguage, detections: [DetectedRegion]?, publishing: (@Sendable ([TextRegion]) -> Void)? = nil) throws -> [TextRegion] {
        try Task.checkCancellation()
        idleTask?.cancel()
        defer { scheduleUnload() }
        let start = ContinuousClock.now
        let lines = try detectLines(image)
        var result: [TextRegion] = []
        var boxes = lines
        if language == .japanese {
            let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            boxes = detections.map { ComicOCRDecoding.textBoxes($0, bounds: bounds) } ?? []
            if !boxes.isEmpty {
                boxes += lines.filter { line in !boxes.contains { OCRTiling.overlapFraction($0, line) > 0.5 } }
            }
            // With no comic detections, only real DB text lines go to manga-ocr.
            if boxes.isEmpty { boxes = lines }
        }
        do {
            for batch in ComicOCRDecoding.batches(boxes, detections: detections) {
                let regions: [TextRegion]
                if language == .japanese { regions = try readManga(image, boxes: batch, lines: lines) }
                else {
                    let recognizer = language == .korean ? "korean" : language == .english ? "en" : "ch"
                    regions = try readLines(image, lines: batch, recognizer: recognizer, language: language)
                        .filter { !$0.region.text.isEmpty && $0.confidence >= 0.5 }.map(\.region)
                }
                result += regions
                publishing?(regions)
            }
        } catch {
            try Task.checkCancellation()
            if publishing != nil && !result.isEmpty {
                AppLog.error(.reader, "Comic OCR failed after publication", metadata: ["error": "\(error)"])
                throw ComicOCRError.partialFailure
            }
            throw error
        }
        AppLog.debug(.reader, "Comic OCR completed", metadata: [
            "language": "\(language.rawValue)", "regions": "\(result.count)", "duration": "\(start.duration(to: .now))",
        ])
        return result
    }

    /// Read the same lines with multilingual and Korean readers; keep the more
    /// confident result for each line before script-based language classification.
    func languageEvidence(_ image: CGImage) throws -> String {
        try Task.checkCancellation()
        idleTask?.cancel()
        defer { scheduleUnload() }
        let lines = Array(try detectLines(image).prefix(24))
        let multilingual = try readLines(image, lines: lines, recognizer: "ch", language: .japanese)
        let korean = try readLines(image, lines: lines, recognizer: "korean", language: .korean)
        return zip(multilingual, korean).compactMap { ch, ko in
            let best = ko.confidence > ch.confidence && TranslationLanguage.korean.containsOwnScript(ko.region.text) ? ko : ch
            return best.confidence >= 0.5 ? best.region.text : nil
        }.joined(separator: " ")
    }

    func unload() {
        idleTask?.cancel()
        idleTask = nil
        sessions.removeAll()
        dictionaries.removeAll()
        environment = nil
    }

    private func scheduleUnload() {
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            await self?.unload()
        }
    }

    private func session(_ file: String) throws -> ORTSession {
        if let session = sessions[file] { return session }
        if environment == nil { environment = try ORTEnv(loggingLevel: .error) }
        let path = try ComicOCRModels.url(file, at: root).path
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(2)
        try options.setGraphOptimizationLevel(.all)
        // CPU is the baseline. Core ML is opt-in for benchmarking the dynamic
        // DB graph; small recognizers and the quantized decoder stay on CPU.
        let session: ORTSession
        do {
            if file == "ch_PP-OCRv5_mobile_det.onnx",
               ProcessInfo.processInfo.environment["PANELY_OCR_LINE_DEVICE"] == "coreml" {
                try options.appendCoreMLExecutionProvider(withOptionsV2: [
                    "ModelFormat": "MLProgram", "MLComputeUnits": "CPUAndGPU",
                ])
            }
            session = try ORTSession(env: environment!, modelPath: path, sessionOptions: options)
        }
        catch {
            guard ProcessInfo.processInfo.environment["PANELY_OCR_LINE_DEVICE"] == "coreml",
                  file == "ch_PP-OCRv5_mobile_det.onnx" else { throw error }
            AppLog.error(.reader, "Core ML line detector failed to load; using CPU", metadata: ["error": "\(error)"])
            let cpu = try ORTSessionOptions()
            try cpu.setIntraOpNumThreads(2)
            try cpu.setGraphOptimizationLevel(.all)
            session = try ORTSession(env: environment!, modelPath: path, sessionOptions: cpu)
        }
        sessions[file] = session
        return session
    }

    private func dictionary(_ file: String) throws -> [String] {
        if let dictionary = dictionaries[file] { return dictionary }
        let text = try String(contentsOf: ComicOCRModels.url(file, at: root), encoding: .utf8)
            .replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        dictionaries[file] = lines
        return lines
    }

    private func run(_ session: ORTSession, inputs: [String: ORTValue]) throws -> ORTValue {
        try Task.checkCancellation()
        guard let name = try session.outputNames().first else { throw ComicOCRError.invalidOutput }
        let output = try session.run(withInputs: inputs, outputNames: [name], runOptions: nil)
        try Task.checkCancellation()
        guard let value = output[name] else { throw ComicOCRError.invalidOutput }
        return value
    }

    private func detectLines(_ image: CGImage) throws -> [CGRect] {
        var lines: [CGRect] = []
        for (index, tile) in OCRTiling.tiles(width: image.width, height: image.height).enumerated() {
            try Task.checkCancellation()
            guard let crop = image.cropping(to: CGRect(x: 0, y: tile.top, width: image.width, height: tile.height)) else { continue }
            let size = ComicOCRDecoding.detectorSize(width: crop.width, height: crop.height)
            let input = try OCRPixels(crop, width: size.width, height: size.height).tensor()
            let detector = try session("ch_PP-OCRv5_mobile_det.onnx")
            guard let name = try detector.inputNames().first else { throw ComicOCRError.invalidOutput }
            let output = try run(detector, inputs: [name: input])
            let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
            guard shape.count == 4, shape[0] == 1, shape[1] == 1 else { throw ComicOCRError.invalidOutput }
            let boxes = try ComicOCRDecoding.boxes(Self.floats(output), width: shape[3], height: shape[2])
            for box in boxes {
                var rect = CGRect(x: box.minX * CGFloat(crop.width) / CGFloat(shape[3]),
                                  y: box.minY * CGFloat(crop.height) / CGFloat(shape[2]),
                                  width: box.width * CGFloat(crop.width) / CGFloat(shape[3]),
                                  height: box.height * CGFloat(crop.height) / CGFloat(shape[2]))
                if OCRTiling.isWhole(rect, bandHeight: tile.height, isFirst: index == 0, isLast: tile.top + tile.height == image.height) {
                    rect.origin.y += CGFloat(tile.top)
                    if !lines.contains(where: { OCRTiling.overlapFraction($0, rect) > 0.5 }) { lines.append(rect) }
                }
            }
        }
        return lines.sorted { $0.minY < $1.minY }
    }

    private func readLines(_ image: CGImage, lines: [CGRect], recognizer: String, language: TranslationLanguage) throws -> [(region: TextRegion, confidence: Float)] {
        let reader = try session("\(recognizer)_PP-OCRv5_rec_mobile_infer.onnx")
        let dict = try dictionary(recognizer == "ch" ? "ppocrv5_dict.txt" : "ppocrv5_\(recognizer)_dict.txt")
        guard let name = try reader.inputNames().first else { throw ComicOCRError.invalidOutput }
        return try lines.map { rect in
            try Task.checkCancellation()
            guard let crop = image.cropping(to: rect.integral) else { throw ComicOCRError.invalidImage }
            let vertical = language.isWrittenVertically && rect.height > rect.width * 1.5
            var pixels = try OCRPixels(crop, width: crop.width, height: crop.height)
            if vertical && recognizer == "ch" { pixels = pixels.rotatedCounterClockwise() }
            let width = min(4096, max(320, Int(ceil(48 * Double(pixels.width) / Double(pixels.height)))))
            let scaledWidth = min(width, max(1, Int(ceil(48 * Double(pixels.width) / Double(pixels.height)))))
            let input = try pixels.resized(width: scaledWidth, height: 48).tensor(paddedWidth: width)
            let output = try run(reader, inputs: [name: input])
            let decoded = try ComicOCRDecoding.ctc(Self.floats(output), shape: output.tensorTypeAndShapeInfo().shape.map(\.intValue), dictionary: dict)
            return (TextRegion(text: decoded.text, rect: rect, isVertical: vertical, glyphSize: max(1, (vertical ? rect.width : rect.height) * 0.8)), decoded.confidence)
        }
    }

    private func readManga(_ image: CGImage, boxes: [CGRect], lines: [CGRect]) throws -> [TextRegion] {
        guard !boxes.isEmpty else { return [] }
        let encoder = try session("encoder_model_int8.onnx"), decoder = try session("decoder_model_int8.onnx")
        let vocab = try dictionary("vocab.txt")
        guard let encoderName = try encoder.inputNames().first else { throw ComicOCRError.invalidOutput }
        let inputs = try decoder.inputNames()
        guard let tokenName = inputs.first(where: { $0.contains("input_ids") }),
              let hiddenName = inputs.first(where: { $0.contains("encoder_hidden") }) else { throw ComicOCRError.invalidOutput }
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        var result: [TextRegion] = []
        for start in stride(from: 0, to: boxes.count, by: 8) {
            try Task.checkCancellation()
            let batch = Array(boxes[start..<min(start + 8, boxes.count)])
            var pixels: [Float] = []
            for box in batch {
                let expanded = box.insetBy(dx: -box.width * 0.05, dy: -box.height * 0.05).integral.intersection(bounds)
                guard let crop = image.cropping(to: expanded) else { throw ComicOCRError.invalidImage }
                pixels += try OCRPixels(crop, width: 224, height: 224).normalized(grayscale: true)
            }
            let input = try Self.tensor(pixels, shape: [batch.count, 3, 224, 224])
            let hidden = try run(encoder, inputs: [encoderName: input])
            var tokens = [[Int64]](repeating: [2], count: batch.count), finished = [Bool](repeating: false, count: batch.count)
            for _ in 0..<300 {
                try Task.checkCancellation()
                let length = tokens[0].count
                let ids = tokens.flatMap { $0 }
                let data = ids.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
                let value = try ORTValue(tensorData: data, elementType: .int64, shape: [NSNumber(value: batch.count), NSNumber(value: length)])
                let output = try run(decoder, inputs: [tokenName: value, hiddenName: hidden])
                let shape = try output.tensorTypeAndShapeInfo().shape.map(\.intValue)
                guard shape.count == 3, shape[0] == batch.count, shape[1] == length, shape[2] == vocab.count else { throw ComicOCRError.invalidOutput }
                let logitData = try output.tensorData()
                let logits = UnsafeBufferPointer(start: logitData.bytes.assumingMemoryBound(to: Float.self), count: logitData.length / 4)
                defer { withExtendedLifetime(output) {} }
                for b in batch.indices {
                    if finished[b] { tokens[b].append(3); continue }
                    let offset = (b * length + length - 1) * shape[2]
                    let best = (0..<shape[2]).max { logits[offset + $0] < logits[offset + $1] } ?? 3
                    tokens[b].append(Int64(best))
                    finished[b] = best == 3
                }
                if finished.allSatisfy({ $0 }) { break }
            }
            for b in batch.indices {
                // An unterminated sequence is unreliable; never translate a 300-token hallucination.
                guard finished[b] else { throw ComicOCRError.invalidOutput }
                let text = ComicOCRDecoding.manga(tokens[b], vocabulary: vocab)
                guard !text.isEmpty, !MissedText.isNoise(text) else { continue }
                result.append(ComicOCRDecoding.measure(text, box: batch[b], lines: lines))
            }
        }
        return result
    }

    private static func tensor(_ values: [Float], shape: [Int]) throws -> ORTValue {
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape.map { NSNumber(value: $0) })
    }

    private static func floats(_ value: ORTValue) throws -> [Float] {
        guard try value.tensorTypeAndShapeInfo().elementType == .float else { throw ComicOCRError.invalidOutput }
        let data = try value.tensorData()
        return Array(UnsafeBufferPointer(start: data.bytes.assumingMemoryBound(to: Float.self), count: data.length / MemoryLayout<Float>.size))
    }
}

/// RGB pixels, row zero at the top, shared by all model preprocessors.
nonisolated struct OCRPixels {
    let width: Int
    let height: Int
    let rgba: [UInt8]

    init(_ image: CGImage, width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= 24000, height <= 24000 else { throw ComicOCRError.invalidImage }
        self.width = width; self.height = height
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        try bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ComicOCRError.invalidImage }
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        rgba = bytes
    }

    init(width: Int, height: Int, rgba: [UInt8]) { self.width = width; self.height = height; self.rgba = rgba }

    func rotatedCounterClockwise() -> OCRPixels {
        var result = [UInt8](repeating: 0, count: rgba.count)
        for y in 0..<height {
            for x in 0..<width {
                let source = (y * width + x) * 4, target = ((width - 1 - x) * height + y) * 4
                for channel in 0..<4 { result[target + channel] = rgba[source + channel] }
            }
        }
        return OCRPixels(width: height, height: width, rgba: result)
    }

    func resized(width: Int, height: Int) throws -> OCRPixels {
        let data = Data(rgba) as CFData
        guard let provider = CGDataProvider(data: data), let image = CGImage(width: self.width, height: self.height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: self.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ComicOCRError.invalidImage }
        return try OCRPixels(image, width: width, height: height)
    }

    func normalized(grayscale: Bool = false, paddedWidth: Int? = nil) -> [Float] {
        let targetWidth = paddedWidth ?? width, plane = targetWidth * height
        var result = [Float](repeating: 0, count: 3 * plane)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4, o = y * targetWidth + x
                if grayscale {
                    let gray = (0.299 * Float(rgba[i]) + 0.587 * Float(rgba[i + 1]) + 0.114 * Float(rgba[i + 2])) / 127.5 - 1
                    for c in 0..<3 { result[c * plane + o] = gray }
                } else {
                    // PaddleOCR models consume BGR, not RGB.
                    for c in 0..<3 { result[c * plane + o] = Float(rgba[i + 2 - c]) / 127.5 - 1 }
                }
            }
        }
        return result
    }

    func tensor(paddedWidth: Int? = nil) throws -> ORTValue {
        let values = normalized(paddedWidth: paddedWidth)
        let data = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        return try ORTValue(tensorData: data, elementType: .float, shape: [1, 3, NSNumber(value: height), NSNumber(value: paddedWidth ?? width)])
    }
}
