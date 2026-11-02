import AppKit
import CoreGraphics
import Vision

/// Prepares balloon detection during normal startup. Explicit Vision mode also
/// warms its language models: historically their first compile after a new build
/// took about a minute on an M1 Pro. Comic OCR avoids that preparation entirely.
@available(macOS 26.0, *)
nonisolated enum TranslationWarmup {
    static func run() async {
        guard let page = makeSamplePage() else { return }
        // Normal startup never compiles Vision's five language models. The OCR
        // pack loads on demand; Vision's cold start is reserved for fallback.
        if PageTextRecognizer.configuredBackend != .vision {
            _ = await BalloonDetector.shared.detect(page)
            return
        }
        let detection = TranslationLanguageDetector.makeRequest()
        _ = try? await detection.perform(on: page)
        for language in TranslationLanguage.allCases {
            _ = try? await PageTextRecognizer(language: language).recognize(page)
        }
        _ = await BalloonDetector.shared.detect(page)
    }

    /// Page-sized, with text in every script: a small image leaves about half
    /// of the compile for the first real page.
    static func makeSamplePage() -> CGImage? {
        let size = NSSize(width: 1500, height: 2168)
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = context
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let lines = ["안녕하세요 오늘 날씨가 좋네요", "こんにちは、今日はいい天気ですね", "你好，今天天气很好", "你好，今天天氣很好", "Hello, what a nice day"]
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 56), .foregroundColor: NSColor.black,
        ]
        for (index, line) in lines.enumerated() {
            (line as NSString).draw(at: NSPoint(x: 80, y: size.height - 240 - CGFloat(index) * 300), withAttributes: attributes)
        }
        return rep.cgImage
    }
}
