import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import Testing
@testable import Panely

/// How fast the translation pipeline runs, stage by stage and as a whole job.
///
/// Opt-in: it takes minutes and needs Apple Translation's language packs (and
/// Apple Intelligence for speech levels), so it never runs in an ordinary
/// `xcodebuild test`. `scripts/benchmark-translation.sh` turns it on with
/// `TEST_RUNNER_PANELY_BENCHMARK=1` (xcodebuild hands `TEST_RUNNER_`-prefixed
/// variables to the tests without the prefix).
///
/// Every result is a `BENCH` line, printed and appended to
/// `Caches/panely-benchmark/results.txt` in the test host's sandbox. The
/// `job` lines include an `outputDigest` of every balloon found and its
/// translation, so two builds can be checked to translate identically.
nonisolated enum TranslationBenchmark {
    static let environment = ProcessInfo.processInfo.environment
    static var isEnabled: Bool { environment["PANELY_BENCHMARK"] == "1" }
    static var label: String { environment["PANELY_BENCHMARK_LABEL"].flatMap { $0.isEmpty ? nil : $0 } ?? "run" }
    /// Synthetic Japanese pages drawn for the run.
    static var syntheticPageCount: Int { environment["PANELY_BENCHMARK_PAGES"].flatMap(Int.init) ?? 40 }
    /// A real book (a ZIP the test host's sandbox can read — the script
    /// copies it into the sandbox's temporary folder).
    static var bookPath: String? { environment["PANELY_BENCHMARK_BOOK"].flatMap { $0.isEmpty ? nil : $0 } }
    static var bookSource: TranslationLanguage {
        environment["PANELY_BENCHMARK_BOOK_SOURCE"].flatMap(TranslationLanguage.init(rawValue:)) ?? .korean
    }
    static var bookTarget: TranslationLanguage {
        environment["PANELY_BENCHMARK_BOOK_TARGET"].flatMap(TranslationLanguage.init(rawValue:)) ?? .japanese
    }
    static var bookFirstPage: Int { environment["PANELY_BENCHMARK_BOOK_FIRST"].flatMap(Int.init) ?? 0 }
    static var bookPageCount: Int { environment["PANELY_BENCHMARK_BOOK_PAGES"].flatMap(Int.init) ?? 60 }
    static var matchSpeechLevel: Bool { environment["PANELY_BENCHMARK_SPEECH_LEVEL"] != "0" }
    /// Which parts to run: `stages`, `job` (both by default) and
    /// `speechConcurrency` (with `stages`: the model answering 1–4 rewrites
    /// at a time).
    static var parts: Set<String> {
        Set((environment["PANELY_BENCHMARK_PARTS"] ?? "stages,job").split(separator: ",").map(String.init))
    }

    /// How this build's analysis decodes a page. (The one line that differs
    /// between builds: before the analyzer decoded pages itself, it went
    /// through `ImageLoader.load`.)
    @available(macOS 26.0, *)
    static func decode(_ page: ComicPage) async throws -> CGImage {
        try await PageAnalyzer.decode(page)
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    static func format(_ value: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", value) }

    static func summary(_ name: String, _ values: [Double]) -> String {
        guard !values.isEmpty else { return "\(name)N=0" }
        let sorted = values.sorted()
        let total = sorted.reduce(0, +)
        let median = sorted[sorted.count / 2]
        let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
        return "\(name)N=\(sorted.count) \(name)Total=\(format(total)) \(name)Median=\(format(median)) \(name)P90=\(format(p90))"
    }

    static let resultsURL: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = caches.appendingPathComponent("panely-benchmark", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("results.txt")
    }()

    static func emit(_ line: String) {
        let text = "BENCH label=\(label) \(line)"
        print(text)
        let data = Data((text + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: resultsURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: resultsURL)
        }
    }
}

/// The real on-device corrector, timed: how many balloons actually went to
/// the model, and how long those took.
private actor SpeechLevelTiming {
    var modelCalls = 0
    var accepted = 0
    var modelSeconds: [Double] = []
    var skipSeconds = 0.0

    func record(calledModel: Bool, seconds: Double, accepted wasAccepted: Bool) {
        if calledModel {
            modelCalls += 1
            modelSeconds.append(seconds)
        } else {
            skipSeconds += seconds
        }
        if wasAccepted { accepted += 1 }
    }
}

private nonisolated struct TimedSpeechLevelCorrector: SpeechLevelCorrecting {
    let inner: any SpeechLevelCorrecting
    let timing: SpeechLevelTiming
    let source: TranslationLanguage
    let target: TranslationLanguage

    /// Whether `correct` will ask the model — the corrector's own gate.
    static func asksModel(_ translation: String, source text: String, from source: TranslationLanguage, to target: TranslationLanguage) -> Bool {
        guard let wanted = SpeechLevelRules.level(ofSource: text, language: source),
              let have = SpeechLevelRules.level(ofTranslation: translation, language: target)
        else { return false }
        return SpeechLevelRules.needsRewrite(translation: have, original: wanted)
    }

    func correct(_ translation: String, source text: String) async -> String? {
        let asks = Self.asksModel(translation, source: text, from: source, to: target)
        let start = ContinuousClock.now
        let result = await inner.correct(translation, source: text)
        await timing.record(calledModel: asks, seconds: TranslationBenchmark.seconds(start.duration(to: .now)), accepted: result != nil)
        return result
    }
}

/// How late the main actor gets to run while a job publishes its results.
@MainActor
private final class MainActorLagMonitor {
    private var task: Task<Void, Never>?
    private(set) var maxLag = 0.0
    private(set) var hitches = 0
    private(set) var samples = 0

    func start() {
        task = Task { @MainActor [weak self] in
            let tick = Duration.milliseconds(5)
            while !Task.isCancelled {
                let start = ContinuousClock.now
                try? await Task.sleep(for: tick)
                let lag = TranslationBenchmark.seconds(start.duration(to: .now) - tick)
                guard let self else { return }
                samples += 1
                maxLag = max(maxLag, lag)
                // A frame at 60 Hz.
                if lag > 0.016 { hitches += 1 }
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }
}

/// Synthetic manga pages with varied Japanese balloons — the gallery's two
/// layouts, filled with different lines so the job doesn't just reuse the
/// same few translations.
@MainActor
private enum BenchmarkPages {
    static let size = CGSize(width: 1600, height: 2400)

    private static let subjects = ["今日は", "明日も", "ここで", "あの人は", "彼女は", "みんなは", "先生は", "僕たちは", "お前は", "この町は", "あいつは", "私は"]
    private static let predicates = [
        "行くぞ", "待ってる", "知らない", "帰ります", "眠いです", "やめろ", "まだだ",
        "来ました", "忘れた", "大丈夫です", "走れ", "見てない", "いいよ", "寒いね",
    ]

    static func page(_ index: Int) -> TranslationSnapshotContent.Page {
        let template = TranslationSnapshotContent.pages[index % TranslationSnapshotContent.pages.count]
        let balloons = template.balloons.enumerated().map { number, balloon in
            if balloon.isCaption {
                return TranslationSnapshotContent.Balloon(
                    frame: balloon.frame, columns: ["第\(index + 1)話、その朝は静かだった。"], translation: "", isCaption: true
                )
            }
            let subject = subjects[(index * 3 + number) % subjects.count]
            let predicate = predicates[(index * 5 + number * 7) % predicates.count]
            return TranslationSnapshotContent.Balloon(frame: balloon.frame, columns: [subject, predicate], translation: "")
        }
        return TranslationSnapshotContent.Page(panels: template.panels, balloons: balloons, hue: template.hue + CGFloat(index) * 0.013)
    }

    /// `count` pages as JPEGs in a ZIP, opened the way the reader opens a book.
    static func makeBook(count: Int) async throws -> [ComicPage] {
        let dir = try Fixture.makeTempDir()
        let content = dir.appendingPathComponent("book", isDirectory: true)
        try FileManager.default.createDirectory(at: content, withIntermediateDirectories: true)
        for index in 0..<count {
            let context = try #require(CGContext(
                data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ))
            context.interpolationQuality = .high
            let drawn = TranslationSnapshotContent.original(page(index))
            context.draw(try #require(drawn.cgImage(forProposedRect: nil, context: nil, hints: nil)), in: CGRect(origin: .zero, size: size))
            let image = try #require(context.makeImage())
            let jpeg = try #require(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.85]))
            try jpeg.write(to: content.appendingPathComponent(String(format: "%03d.jpg", index)))
        }
        let zip = dir.appendingPathComponent("synthetic.cbz")
        try Fixture.zipDirectory(content, to: zip)
        return try await ArchiveLoader.load(from: zip).pages
    }
}

@MainActor
@Suite(.serialized, .enabled(if: TranslationBenchmark.isEnabled))
struct TranslationBenchmarkTests {
    @Test func syntheticJapaneseToKorean() async throws {
        guard #available(macOS 26.0, *) else { return }
        let pages = try await BenchmarkPages.makeBook(count: TranslationBenchmark.syntheticPageCount)
        try await run(name: "synthetic", pages: pages, source: .japanese, target: .korean)
    }

    @Test func realBook() async throws {
        guard #available(macOS 26.0, *) else { return }
        guard let path = TranslationBenchmark.bookPath else {
            TranslationBenchmark.emit("part=book skipped=noBook")
            return
        }
        let all = try await ArchiveLoader.load(from: URL(fileURLWithPath: path)).pages
        let first = min(TranslationBenchmark.bookFirstPage, all.count)
        let pages = Array(all[first..<min(all.count, first + TranslationBenchmark.bookPageCount)])
        try await run(name: "book", pages: pages, source: TranslationBenchmark.bookSource, target: TranslationBenchmark.bookTarget)
    }

    // MARK: -

    @available(macOS 26.0, *)
    private func run(name: String, pages: [ComicPage], source: TranslationLanguage, target: TranslationLanguage) async throws {
        let status = await TranslationAvailability.status(from: source, to: target, mode: .fast)
        let speech = SpeechLevelAvailability.current
        TranslationBenchmark.emit(
            "part=\(name).env pages=\(pages.count) pair=\(source.rawValue)-\(target.rawValue) translation=\(status) fastMode=\(TranslationMode.isFastAvailable) "
                + "speechLevel=\(speech) speechLevelPair=\(SpeechLevelRules.supports(from: source, to: target)) matchSpeechLevel=\(TranslationBenchmark.matchSpeechLevel) "
                + "cores=\(ProcessInfo.processInfo.activeProcessorCount) thermal=\(ProcessInfo.processInfo.thermalState.rawValue) debugAssertions=\(_isDebugAssertConfiguration())"
        )
        if TranslationBenchmark.parts.contains("stages") {
            try await stages(name: name, pages: pages, source: source, target: target, canTranslate: status == .installed)
        }
        if TranslationBenchmark.parts.contains("job") {
            guard status == .installed else {
                TranslationBenchmark.emit("part=\(name).job skipped=translation-\(status)")
                return
            }
            try await job(name: name, pages: pages, source: source, target: target)
        }
    }

    /// Each stage on its own, page by page at the job's priority, then the
    /// analysis as the job runs it (several pages side by side).
    @available(macOS 26.0, *)
    private func stages(name: String, pages: [ComicPage], source: TranslationLanguage, target: TranslationLanguage, canTranslate: Bool) async throws {
        let plan = TranslationPlan.pages(count: pages.count)
        let line = try await Task.detached(priority: .utility) { () -> String in
            // Warm-up: model loading isn't what's measured.
            let warm = try await TranslationBenchmark.decode(pages[0])
            _ = await BalloonDetector.shared.detect(warm)
            _ = try await PageTextRecognizer(language: source).recognize(warm)

            var read: [Double] = [], decode: [Double] = [], detect: [Double] = [], ocr: [Double] = [], analyze: [Double] = []
            var rereadBoxes = 0
            for (index, page) in pages.enumerated() {
                var start = ContinuousClock.now
                if case let .archiveEntry(reader, path) = page.source {
                    _ = try await reader.loadData(at: path)
                    read.append(TranslationBenchmark.seconds(start.duration(to: .now)))
                }
                start = .now
                let image = try await TranslationBenchmark.decode(page)
                decode.append(TranslationBenchmark.seconds(start.duration(to: .now)))
                start = .now
                let detections = await BalloonDetector.shared.detect(image)
                detect.append(TranslationBenchmark.seconds(start.duration(to: .now)))
                start = .now
                let regions = try await PageTextRecognizer(language: source).recognize(image)
                ocr.append(TranslationBenchmark.seconds(start.duration(to: .now)))
                if let detections { rereadBoxes += MissedText.boxesToReread(detections, regions: regions).count }
                start = .now
                _ = try await PageAnalyzer(pages: pages, language: source).analyze(plan.units[index], plan: plan)
                analyze.append(TranslationBenchmark.seconds(start.duration(to: .now)))
            }
            return [
                "part=\(name).stages",
                TranslationBenchmark.summary("read", read), TranslationBenchmark.summary("decode", decode),
                TranslationBenchmark.summary("detect", detect), TranslationBenchmark.summary("ocr", ocr),
                "rereadBoxes=\(rereadBoxes)", TranslationBenchmark.summary("analyzeSerial", analyze),
                // What the full analysis spends beyond decode + OCR (detection
                // runs alongside OCR): mostly the rereads.
                "analyzeOverheadTotal=\(TranslationBenchmark.format(analyze.reduce(0, +) - decode.reduce(0, +) - ocr.reduce(0, +)))",
            ].joined(separator: " ")
        }.value
        TranslationBenchmark.emit(line)

        // The job's way: one analyzer, `fastLookahead` pages at once, utility priority.
        let width = TranslationController.fastLookahead
        let (parallel, analyses) = try await Task.detached(priority: .utility) { () -> (Double, [PageAnalysis]) in
            let analyzer = PageAnalyzer(pages: pages, language: source)
            let start = ContinuousClock.now
            var results: [PageAnalysis] = []
            try await withThrowingTaskGroup(of: [PageAnalysis].self) { group in
                for (index, unit) in plan.units.enumerated() {
                    if index >= width, let done = try await group.next() { results += done }
                    group.addTask { try await analyzer.analyze(unit, plan: plan) }
                }
                for try await done in group { results += done }
            }
            return (TranslationBenchmark.seconds(start.duration(to: .now)), results.sorted { $0.pageIndex < $1.pageIndex })
        }.value
        let balloons = analyses.flatMap(\.bubbles)
        TranslationBenchmark.emit(
            "part=\(name).analysis width=\(width) wall=\(TranslationBenchmark.format(parallel)) pagesPerSecond=\(TranslationBenchmark.format(Double(pages.count) / parallel)) balloons=\(balloons.count)"
        )

        guard canTranslate else {
            TranslationBenchmark.emit("part=\(name).translate skipped=translation-unavailable")
            return
        }
        // Each distinct line once, as the job does.
        var seen = Set<String>()
        let sources = balloons.map(\.source).filter { seen.insert($0).inserted }
        let translated = try await Task.detached(priority: .utility) { () -> ([(String, String)], [Double]) in
            let translator = PageTranslator(from: source, to: target, mode: .fast)
            _ = try await translator.translate(sources.first ?? "テスト")
            var times: [Double] = []
            var pairs: [(String, String)] = []
            for text in sources {
                let start = ContinuousClock.now
                let translation = try await translator.translate(text)
                times.append(TranslationBenchmark.seconds(start.duration(to: .now)))
                pairs.append((text, translation))
            }
            return (pairs, times)
        }.value
        TranslationBenchmark.emit("part=\(name).translate \(TranslationBenchmark.summary("balloon", translated.1))")

        guard let corrector = SpeechLevelCorrectors.make(from: source, to: target) else {
            TranslationBenchmark.emit("part=\(name).speechLevel skipped=unavailable")
            return
        }
        let pairs = translated.0
        let speechLine = await Task.detached(priority: .utility) { () -> String in
            var model: [Double] = []
            var skipped = 0.0
            var accepted = 0
            if let first = pairs.first(where: { TimedSpeechLevelCorrector.asksModel($0.1, source: $0.0, from: source, to: target) }) {
                _ = await corrector.correct(first.1, source: first.0)
            }
            for (text, translation) in pairs {
                let asks = TimedSpeechLevelCorrector.asksModel(translation, source: text, from: source, to: target)
                let start = ContinuousClock.now
                let result = await corrector.correct(translation, source: text)
                let elapsed = TranslationBenchmark.seconds(start.duration(to: .now))
                if asks { model.append(elapsed) } else { skipped += elapsed }
                if result != nil { accepted += 1 }
            }
            return "part=\(name).speechLevel balloons=\(pairs.count) accepted=\(accepted) skipSeconds=\(TranslationBenchmark.format(skipped)) "
                + TranslationBenchmark.summary("modelCall", model)
        }.value
        TranslationBenchmark.emit(speechLine)

        // Whether the model answers faster several at a time, and the same.
        guard TranslationBenchmark.parts.contains("speechConcurrency") else { return }
        let asked = pairs.filter { TimedSpeechLevelCorrector.asksModel($0.1, source: $0.0, from: source, to: target) }
        var reference: [String?] = []
        for width in [1, 2, 3, 4] {
            let (wall, answers) = await Task.detached(priority: .utility) { () -> (Double, [String?]) in
                var answers = [String?](repeating: nil, count: asked.count)
                let start = ContinuousClock.now
                await withTaskGroup(of: (Int, String?).self) { group in
                    for (index, (text, translation)) in asked.enumerated() {
                        if index >= width, let (done, answer) = await group.next() { answers[done] = answer }
                        group.addTask { (index, await corrector.correct(translation, source: text)) }
                    }
                    for await (done, answer) in group { answers[done] = answer }
                }
                return (TranslationBenchmark.seconds(start.duration(to: .now)), answers)
            }.value
            if width == 1 { reference = answers }
            let differing = zip(answers, reference).filter { $0 != $1 }.count
            TranslationBenchmark.emit(
                "part=\(name).speechConcurrency width=\(width) calls=\(asked.count) wall=\(TranslationBenchmark.format(wall)) "
                    + "perCall=\(TranslationBenchmark.format(wall / Double(max(1, asked.count)))) differFromSerial=\(differing)"
            )
        }
    }

    /// A whole translation job, the way the app runs one, with its own stats line.
    @available(macOS 26.0, *)
    private func job(name: String, pages: [ComicPage], source: TranslationLanguage, target: TranslationLanguage) async throws {
        let store = TranslationStore(root: try Fixture.makeTempDir().appendingPathComponent("translations", isDirectory: true))
        let controller = TranslationController(store: store, defaults: InMemoryKeyValueStore())
        let timing = SpeechLevelTiming()
        controller.makeSpeechLevelCorrector = { source, target in
            SpeechLevelCorrectors.make(from: source, to: target).map {
                TimedSpeechLevelCorrector(inner: $0, timing: timing, source: source, target: target)
            }
        }
        let statsBefore = await jobStatsLines().count
        let monitor = MainActorLagMonitor()
        monitor.start()
        let start = ContinuousClock.now
        controller.reload(
            pages: pages, pageSizes: [], scope: .page, source: source, target: target, mode: .fast,
            matchSpeechLevel: TranslationBenchmark.matchSpeechLevel, enabled: true, autoStart: true, focusPage: 0
        )
        await controller.cacheTask?.value
        let deadline = ContinuousClock.now + .seconds(60 * 60)
        while controller.phase != .idle, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        let wall = TranslationBenchmark.seconds(start.duration(to: .now))
        monitor.stop()
        #expect(controller.notice == nil)
        #expect(controller.completedPageCount == pages.count)

        // Everything found and how it came out, to compare builds.
        var digest = SHA256()
        var balloons = 0
        var translatedBalloons = 0
        for (index, page) in pages.enumerated() {
            for bubble in controller.pages[page.id]?.bubbles ?? [] {
                balloons += 1
                if bubble.translation?.isEmpty == false { translatedBalloons += 1 }
                let rect = bubble.rect.integral
                digest.update(data: Data("\(index)|\(rect)|\(bubble.source)|\(bubble.translation ?? "∅")\n".utf8))
            }
        }
        let outputDigest = digest.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()

        var stats = ""
        for _ in 0..<100 {
            let lines = await jobStatsLines()
            if lines.count > statsBefore, let last = lines.last {
                stats = String(last.split(separator: "Translation job stats", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let modelCalls = await timing.modelCalls
        let modelSeconds = await timing.modelSeconds
        let accepted = await timing.accepted
        let skip = await timing.skipSeconds
        TranslationBenchmark.emit(
            "part=\(name).job wall=\(TranslationBenchmark.format(wall)) balloons=\(balloons) translatedBalloons=\(translatedBalloons) outputDigest=\(outputDigest) "
                + "speechModelCalls=\(modelCalls) speechAccepted=\(accepted) speechSkipSeconds=\(TranslationBenchmark.format(skip)) \(TranslationBenchmark.summary("speechModelCall", modelSeconds)) "
                + "mainMaxLag=\(TranslationBenchmark.format(monitor.maxLag)) mainHitches=\(monitor.hitches) mainSamples=\(monitor.samples) "
                + "stats[\(stats)]"
        )
    }

    private func jobStatsLines() async -> [Substring] {
        await DiagnosticLogStore.shared.recentLogText().split(separator: "\n").filter { $0.contains("Translation job stats") }
    }
}
