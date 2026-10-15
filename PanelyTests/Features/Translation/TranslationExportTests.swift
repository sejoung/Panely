import CoreGraphics
import Foundation
import ImageIO
import Testing
import ZIPFoundation
@testable import Panely

/// Painting a page's translations into its image, and writing the pages out.
struct TranslatedPageRendererTests {
    @Test func patchIsPaintedAndTheRestIsUntouched() throws {
        let image = try #require(makeImage(width: 40, height: 40, gray: 1))
        var bubble = makeTranslatedPage("가", width: 40, height: 40).bubbles[0]
        bubble.rect = CGRect(x: 10, y: 10, width: 20, height: 10)
        bubble.glyphSize = 4
        bubble.background = BubbleBackground(red: 0, green: 0, blue: 0, isUniform: true)
        let patch = TranslationOverlayLayout.patchRect(for: bubble, imageSize: CGSize(width: 40, height: 40))

        let rendered = try #require(TranslatedPageRenderer.render(
            image,
            bubbles: [.init(bubble: bubble, patch: patch)],
            pageSize: CGSize(width: 40, height: 40)
        ))

        // Top-left origin: just inside the patch's top edge (above the text,
        // clear of its rounded corners) is the balloon's black; flipped the
        // wrong way it would land lower down. The page's corner stays white.
        #expect(gray(of: rendered, x: Int(patch.midX), y: Int(patch.minY) + 2) < 0.2)
        #expect(gray(of: rendered, x: Int(patch.midX), y: 36) > 0.9)
        #expect(gray(of: rendered, x: 1, y: 1) > 0.9)
        #expect(rendered.width == 40 && rendered.height == 40)
    }

    @Test func stripBalloonReachingIntoTheNextPageIsDrawnThereToo() {
        var above = makeTranslatedPage("위", width: 100, height: 100)
        above.bubbles[0].rect = CGRect(x: 10, y: 90, width: 20, height: 30)
        let below = TranslatedPage(imageWidth: 100, imageHeight: 100, bubbles: [])

        let carried = TranslatedPageRenderer.bubbles(for: 1, in: [above, below], scope: .strip)
        #expect(carried.count == 1)
        #expect((carried.first?.patch.minY ?? 0) < 0)
        #expect(TranslatedPageRenderer.bubbles(for: 1, in: [above, below], scope: .page).isEmpty)
    }

    @Test func emptyAndHiddenTranslationsAreNotDrawn() {
        var page = makeTranslatedPage("", width: 10, height: 10)
        #expect(TranslatedPageRenderer.bubbles(for: 0, in: [page], scope: .page).isEmpty)
        page.bubbles[0].translation = nil
        #expect(TranslatedPageRenderer.bubbles(for: 0, in: [page], scope: .page).isEmpty)
    }
}

struct TranslationExportWriterTests {
    @Test func cbzHoldsEveryPageInOrderAndCopiesUntranslatedOnes() async throws {
        let pages = Fixture.makeImagePages(count: 3)
        let folder = try Fixture.makeTempDir()
        let writer = TranslationExportWriter(
            pages: pages,
            translations: [pages[1].id: makeTranslatedPage("둘")],
            scope: .page,
            format: .cbz
        )

        let result = try await writer.write(into: folder, name: "Book [Korean]") { _, _ in }

        #expect(result.url.lastPathComponent == "Book [Korean].cbz")
        #expect(result.bytes > 0)
        let archive = try Archive(url: result.url, accessMode: .read)
        #expect(archive.map(\.path).sorted() == ["001.png", "002.png", "003.png"])
        let original = try Data(contentsOf: try #require(fileURL(of: pages[0])))
        #expect(try entryData(archive, "001.png") == original)
        #expect(try entryData(archive, "002.png") != original)
        // Nothing half-written left behind.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".partial") }
        #expect(leftovers.isEmpty)
    }

    @Test func takenNamesAreNumberedAndFoldersWork() async throws {
        let pages = Fixture.makeImagePages(count: 2)
        let folder = try Fixture.makeTempDir()
        let writer = TranslationExportWriter(pages: pages, translations: [:], scope: .page, format: .folder)

        let first = try await writer.write(into: folder, name: "Book") { _, _ in }
        let second = try await writer.write(into: folder, name: "Book") { _, _ in }

        #expect(first.url.lastPathComponent == "Book")
        #expect(second.url.lastPathComponent == "Book 2")
        #expect(try FileManager.default.contentsOfDirectory(atPath: second.url.path).sorted() == ["001.png", "002.png"])
    }

    @Test func zipIsTheSameArchiveUnderItsOwnExtension() async throws {
        let pages = Fixture.makeImagePages(count: 2)
        let folder = try Fixture.makeTempDir()
        let writer = TranslationExportWriter(pages: pages, translations: [:], scope: .page, format: .zip)

        let result = try await writer.write(into: folder, name: "Book") { _, _ in }

        #expect(result.url.lastPathComponent == "Book.zip")
        let archive = try Archive(url: result.url, accessMode: .read)
        #expect(archive.map(\.path).sorted() == ["001.png", "002.png"])
    }

    @Test func cancellingLeavesNothingBehind() async throws {
        let pages = Fixture.makeImagePages(count: 5)
        let folder = try Fixture.makeTempDir()
        let writer = TranslationExportWriter(pages: pages, translations: [:], scope: .page, format: .cbz)

        let task = Task.detached { try await writer.write(into: folder, name: "Book") { _, _ in } }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func fileNamesLoseOnlyPathSeparators() {
        #expect(TranslationExportWriter.safeFileName("A/B: C [한국어]") == "A-B- C [한국어]")
        #expect(TranslationExportWriter.entryName(9, digits: 3, ext: "jpg") == "010.jpg")
    }
}

/// The whole flow from the reader: a book's cached translations and edits
/// written out in the background, then listed as exported.
@MainActor
struct ReaderViewModelTranslationExportTests {
    private struct Setup {
        let vm: ReaderViewModel
        let book: URL
        let pages: [ComicPage]
        let output: URL
    }

    /// A folder book not open in the reader, its series' language known, and
    /// a translation cached for its first page.
    private func makeSetup(cacheFirstPage: Bool = true) async throws -> Setup {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        let series = try Fixture.makeTempDir()
        let book = series.appendingPathComponent("Vol01", isDirectory: true)
        try FileManager.default.createDirectory(at: book, withIntermediateDirectories: true)
        let png = try Fixture.makePNG(width: 10, height: 10)
        for index in 1...2 {
            try png.write(to: book.appendingPathComponent("p\(index).png"))
        }
        let pages = try FolderLoader.load(from: book).pages
        let seriesID = try #require(ReaderSeriesIdentity.make(for: book, opened: nil, tempRoot: nil))
        vm.seriesPreferences.setTranslationSource(.japanese, forSeries: seriesID)
        if cacheFirstPage {
            try vm.translationManager.store.save(
                makeTranslatedPage("하나"),
                key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .korean)
            )
        }
        let output = try Fixture.makeTempDir()
        vm.translationExports.setDestination(output)
        return Setup(vm: vm, book: book, pages: pages, output: output)
    }

    private func export(_ setup: Setup, untranslated: UntranslatedPagesPolicy = .exportAsIs) {
        setup.vm.requestTranslationExport(books: [setup.book], title: "Vol01", isSeries: false)
        guard let request = setup.vm.translationExportRequest else {
            Issue.record("no export request")
            return
        }
        setup.vm.startTranslationExport(request, options: TranslationExportOptions(target: .korean, format: .cbz, untranslated: untranslated))
    }

    @Test func exportsABookThatIsNotOpenAndListsIt() async throws {
        let setup = try await makeSetup()

        export(setup)
        try await waitUntil { !setup.vm.translationExports.history.isEmpty || !setup.vm.translationExports.stoppedJobs.isEmpty }

        let record = try #require(setup.vm.translationExports.history.first)
        #expect(record.title == "Vol01")
        #expect(record.pageCount == 2)
        #expect(record.url.lastPathComponent == "Vol01 [Korean].cbz")
        #expect(setup.vm.translationExports.activeJobs.isEmpty)
        #expect(setup.vm.translationExports.unseenFinishedCount == 1)
        let archive = try Archive(url: record.url, accessMode: .read)
        #expect(archive.map(\.path).sorted() == ["001.png", "002.png"])
        // The second page had nothing translated: copied as it was.
        let original = try Data(contentsOf: try #require(fileURL(of: setup.pages[1])))
        #expect(try entryData(archive, "002.png") == original)
        #expect(try entryData(archive, "001.png") != original)

        // Remembered across launches.
        let reloaded = TranslationExportManager(defaults: setup.vm.dependencies.keyValueStore)
        #expect(reloaded.history == setup.vm.translationExports.history)
    }

    @Test func hiddenBalloonsAreLeftOut() async throws {
        let setup = try await makeSetup()
        var edits = PageEdits()
        edits.update(makeTranslatedPage("하나").bubbles[0]) { $0.isHidden = true }
        try setup.vm.dependencies.translationEditStore.save(edits, key: TranslationEditStore.key(pageID: setup.pages[0].id, scope: .page))

        export(setup)
        try await waitUntil { !setup.vm.translationExports.history.isEmpty || !setup.vm.translationExports.stoppedJobs.isEmpty }

        // Its only balloon hidden, the page has nothing left to show.
        #expect(setup.vm.translationExports.history.isEmpty)
        if case .failed = setup.vm.translationExports.stoppedJobs.first?.stage {} else {
            Issue.record("expected the export to stop with nothing translated")
        }
    }

    @Test func nothingTranslatedStopsWithAReasonAndCanBeRetried() async throws {
        let setup = try await makeSetup(cacheFirstPage: false)

        export(setup)
        try await waitUntil { !setup.vm.translationExports.stoppedJobs.isEmpty }

        let job = try #require(setup.vm.translationExports.stoppedJobs.first)
        #expect(job.stage == .failed(TranslationExportError.nothingTranslated.errorDescription ?? ""))

        // Translated meanwhile: trying again exports it.
        try setup.vm.translationManager.store.save(
            makeTranslatedPage("하나"),
            key: TranslationStore.key(pageID: setup.pages[0].id, from: .japanese, to: .korean)
        )
        setup.vm.retryTranslationExport(job)
        try await waitUntil { !setup.vm.translationExports.history.isEmpty }
        #expect(setup.vm.translationExports.stoppedJobs.isEmpty)
    }

    @Test func withoutAFolderNothingStarts() async throws {
        let vm = makeTestViewModel()
        vm.translationEnabled = true
        let book = try Fixture.makeTempDir()

        vm.requestTranslationExport(books: [book], title: "Book", isSeries: false)
        let request = try #require(vm.translationExportRequest)
        vm.startTranslationExport(request, options: TranslationExportOptions(target: .korean))
        try await waitUntil { !vm.translationExports.stoppedJobs.isEmpty }

        #expect(vm.translationExports.stoppedJobs.first?.stage == .failed(TranslationExportError.noDestination.errorDescription ?? ""))
    }
}

// MARK: - Helpers

private func makeImage(width: Int, height: Int, gray: CGFloat) -> CGImage? {
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    context.setFillColor(CGColor(gray: gray, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

/// Brightness (0–1) at (`x`, `y`), top-left origin.
private func gray(of image: CGImage, x: Int, y: Int) -> Double {
    var pixel = [UInt8](repeating: 0, count: 4)
    let context = CGContext(
        data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
    return (Double(pixel[0]) + Double(pixel[1]) + Double(pixel[2])) / (3 * 255)
}

private func fileURL(of page: ComicPage) -> URL? {
    if case .file(let url) = page.source { return url }
    return nil
}

private func entryData(_ archive: Archive, _ path: String) throws -> Data {
    guard let entry = archive[path] else { throw ArchiveReaderError.entryNotFound(path) }
    var data = Data()
    _ = try archive.extract(entry) { data.append($0) }
    return data
}
