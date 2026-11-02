import CoreGraphics
import Foundation

/// Model-independent postprocessing, following PanelyWindows' OCR adapters.
nonisolated enum ComicOCRDecoding {
    static func manga(_ tokens: [Int64], vocabulary: [String]) -> String {
        var text = ""
        for token in tokens {
            if token == 3 { break }
            if token >= 5, token < vocabulary.count { text += vocabulary[Int(token)] }
        }
        text = text.filter { !$0.isWhitespace }.replacingOccurrences(of: "…", with: "...")
        text = text.replacingOccurrences(of: "[・.]{2,}", with: "...", options: .regularExpression)
        return String(String.UnicodeScalarView(text.unicodeScalars.map { scalar in
            (0x21...0x7E).contains(scalar.value) ? Unicode.Scalar(scalar.value + 0xFEE0)! : scalar
        }))
    }

    static func ctc(_ values: [Float], shape: [Int], dictionary: [String]) throws -> (text: String, confidence: Float) {
        guard shape.count == 3, shape[0] == 1, shape[1] > 0, shape[2] > 0,
              values.count == shape[1] * shape[2] else { throw ComicOCRError.invalidOutput }
        // Use the dictionary size, not T > C: long English lines can have more steps than classes.
        let validClasses = [dictionary.count + 1, dictionary.count + 2]
        let transposed = !validClasses.contains(shape[2]) && validClasses.contains(shape[1])
        let steps = shape[transposed ? 2 : 1], classes = shape[transposed ? 1 : 2]
        guard validClasses.contains(classes) else { throw ComicOCRError.invalidOutput }
        var text = "", last = -1, count = 0
        var confidence: Float = 0
        for t in 0..<steps {
            let row = (0..<classes).map { values[transposed ? $0 * steps + t : t * classes + $0] }
            guard let best = row.indices.max(by: { row[$0] < row[$1] }) else { continue }
            if best != 0, best != last {
                let character = best <= dictionary.count ? dictionary[best - 1] : " "
                if !character.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) {
                    text += character
                    if row.contains(where: { $0 < 0 || $0 > 1 }) {
                        let maximum = row[best]
                        confidence += 1 / row.reduce(Float(0)) { $0 + exp($1 - maximum) }
                    } else { confidence += row[best] }
                    count += 1
                }
            }
            last = best
        }
        return (text.trimmingCharacters(in: .whitespacesAndNewlines), count > 0 ? confidence / Float(count) : 0)
    }

    static func detectorSize(width: Int, height: Int, maxDimension: Int = 2400) -> (width: Int, height: Int) {
        var ratio = max(1, 960 / Double(max(1, min(width, height))))
        ratio = min(ratio, Double(max(32, maxDimension)) / Double(max(1, max(width, height))))
        func snap(_ value: Int) -> Int { max(32, Int((Double(value) * ratio / 32).rounded()) * 32) }
        return (snap(width), snap(height))
    }

    /// DB probability map -> connected components -> expanded text-line boxes.
    static func boxes(_ values: [Float], width: Int, height: Int) throws -> [CGRect] {
        guard width > 0, height > 0, values.count == width * height else { throw ComicOCRError.invalidOutput }
        var seen = [Bool](repeating: false, count: values.count)
        var boxes: [CGRect] = []
        for start in values.indices where values[start] > 0.3 && !seen[start] {
            if start % 4096 == 0 { try Task.checkCancellation() }
            var stack = [start], minX = width, minY = height, maxX = 0, maxY = 0, count = 0
            var score: Float = 0
            seen[start] = true
            while let pixel = stack.popLast() {
                let x = pixel % width, y = pixel / width
                minX = min(minX, x); maxX = max(maxX, x)
                minY = min(minY, y); maxY = max(maxY, y)
                count += 1; score += values[pixel]
                if count % 4096 == 0 { try Task.checkCancellation() }
                for neighbor in [x > 0 ? pixel - 1 : -1, x + 1 < width ? pixel + 1 : -1,
                                 y > 0 ? pixel - width : -1, y + 1 < height ? pixel + width : -1]
                where neighbor >= 0 && !seen[neighbor] && values[neighbor] > 0.3 {
                    seen[neighbor] = true
                    stack.append(neighbor)
                }
            }
            let w = CGFloat(maxX - minX + 1), h = CGFloat(maxY - minY + 1)
            guard min(w, h) >= 3, score / Float(count) >= 0.5 else { continue }
            let distance = w * h / (w + h)
            boxes.append(CGRect(x: CGFloat(minX), y: CGFloat(minY), width: w, height: h)
                .insetBy(dx: -distance, dy: -distance)
                .intersection(CGRect(x: 0, y: 0, width: width, height: height)))
        }
        return boxes.sorted { $0.minY == $1.minY ? $0.minX < $1.minX : $0.minY < $1.minY }
    }

    static func textBoxes(_ detections: [DetectedRegion], bounds: CGRect) -> [CGRect] {
        var boxes: [CGRect] = []
        for detection in detections.sorted(by: { $0.score > $1.score })
        where detection.kind != .balloon && detection.score >= MissedText.minimumScore {
            let rect = detection.rect.intersection(bounds).integral.intersection(bounds)
            guard !rect.isNull, rect.width >= 4, rect.height >= 4,
                  !boxes.contains(where: { OCRTiling.overlapFraction($0, rect) > 0.5 }) else { continue }
            boxes.append(rect)
        }
        return boxes
    }

    static func measure(_ text: String, box: CGRect, lines: [CGRect]) -> TextRegion {
        func estimate(_ rect: CGRect) -> CGFloat {
            min(max(8, sqrt(rect.width * rect.height / CGFloat(max(1, text.filter { !$0.isWhitespace }.count))) * 0.8), max(8, min(rect.width, rect.height)))
        }
        let fallback = TextRegion(text: text, rect: box, isVertical: box.height > box.width * 1.15, glyphSize: estimate(box))
        let inside = lines.filter { $0.intersection(box).area >= $0.area * 0.5 }
        guard let first = inside.first else { return fallback }
        let tight = inside.dropFirst().reduce(first) { $0.union($1) }.intersection(box)
        guard !tight.isEmpty else { return fallback }
        let vertical = inside.filter { $0.height > $0.width * 1.2 }.count * 2 >= inside.count
        let thickness = inside.map { vertical ? $0.width : $0.height }.sorted()
        let measured = thickness[thickness.count / 2] * 0.8
        guard measured >= estimate(tight) * 0.5 else { return fallback }
        return TextRegion(text: text, rect: tight, isVertical: vertical, glyphSize: max(6, min(measured, estimate(tight) * 1.2)))
    }

    /// Keep every container complete before publishing: columns from the same
    /// balloon must never be translated as separate partial sentences.
    static func batches(_ boxes: [CGRect], detections: [DetectedRegion]?) -> [[CGRect]] {
        guard let detections, !detections.isEmpty else { return boxes.isEmpty ? [] : [boxes] }
        var groups: [Int: [CGRect]] = [:]
        for box in boxes { groups[BubbleGrouper.container(of: box, in: detections) ?? -1, default: []].append(box) }
        let ordered = groups.values.sorted { a, b in
            let ar = a.dropFirst().reduce(a[0]) { $0.union($1) }, br = b.dropFirst().reduce(b[0]) { $0.union($1) }
            return abs(ar.minY - br.minY) > 1 ? ar.minY < br.minY : ar.midX > br.midX
        }
        var batches: [[CGRect]] = [], batch: [CGRect] = []
        for group in ordered {
            if !batch.isEmpty, batch.count + group.count > 8 { batches.append(batch); batch = [] }
            batch += group
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}

private nonisolated extension CGRect {
    var area: CGFloat { isNull ? 0 : width * height }
}

nonisolated enum ComicOCRError: Error, Equatable {
    case invalidOutput
    case invalidImage
    case partialFailure
}
