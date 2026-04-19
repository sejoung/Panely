import Testing
import Foundation
import AppKit
import ZIPFoundation
@testable import Panely

// MARK: - Test fixtures helpers

private enum Fixture {
    static func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    static func writeFile(_ url: URL, bytes: [UInt8] = [0]) throws -> URL {
        try Data(bytes).write(to: url)
        return url
    }

    static func zipDirectory(_ sourceDir: URL, to zipURL: URL) throws {
        try FileManager.default.zipItem(at: sourceDir, to: zipURL, shouldKeepParent: false)
    }
}

// MARK: - ComicPage

struct ComicPageTests {
    @Test func createsUniqueIDPerInstance() {
        let url = URL(fileURLWithPath: "/tmp/sample.cbz")
        let a = ComicPage(source: .file(url), displayName: "sample")
        let b = ComicPage(source: .file(url), displayName: "sample")
        #expect(a.id != b.id)
    }

    @Test func displayNameIsPreserved() {
        let page = ComicPage(
            source: .file(URL(fileURLWithPath: "/tmp/x.cbz")),
            displayName: "Vol 01"
        )
        #expect(page.displayName == "Vol 01")
    }
}

// MARK: - ComicSource

struct ComicSourceTests {
    @Test func emptySourceIsEmpty() {
        let empty = ComicSource.empty
        #expect(empty.isEmpty)
        #expect(empty.pageCount == 0)
        #expect(empty.title.isEmpty)
    }

    @Test func pageCountReflectsPages() {
        let pages = (1...5).map { i in
            ComicPage(
                source: .file(URL(fileURLWithPath: "/p\(i)")),
                displayName: "\(i)"
            )
        }
        let source = ComicSource(title: "Test", pages: pages)
        #expect(source.pageCount == 5)
        #expect(source.isEmpty == false)
        #expect(source.title == "Test")
    }
}

// MARK: - RecentItem

struct RecentItemTests {
    @Test func codableRoundTripPreservesAllFields() throws {
        let original = RecentItem(
            id: UUID(),
            path: "/Users/demo/Comics/Vol01.cbz",
            title: "Vol01",
            openedAt: Date(timeIntervalSince1970: 1_700_000_000),
            bookmarkData: Data([0x01, 0x02, 0x03, 0x04]),
            isDirectory: false
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(RecentItem.self, from: encoded)

        #expect(decoded.id == original.id)
        #expect(decoded.path == original.path)
        #expect(decoded.title == original.title)
        #expect(decoded.openedAt == original.openedAt)
        #expect(decoded.bookmarkData == original.bookmarkData)
        #expect(decoded.isDirectory == original.isDirectory)
    }

    @Test func legacyJSONWithoutIsDirectoryDecodesAsFile() throws {
        // Simulate data stored before the isDirectory field was added
        let json = """
        {
          "id": "\(UUID().uuidString)",
          "path": "/legacy.cbz",
          "title": "Legacy",
          "openedAt": 757382400.0,
          "bookmarkData": "AQIDBA=="
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(RecentItem.self, from: json)
        #expect(decoded.isDirectory == false)
        #expect(decoded.path == "/legacy.cbz")
        #expect(decoded.bookmarkData == Data([0x01, 0x02, 0x03, 0x04]))
    }

    @Test func folderItemUsesFolderIcon() {
        let item = RecentItem(
            id: UUID(),
            path: "/Library",
            title: "Library",
            openedAt: Date(),
            bookmarkData: Data(),
            isDirectory: true
        )
        #expect(item.iconName == "folder")
    }

    @Test func archiveItemUsesBookIcon() {
        let item = RecentItem(
            id: UUID(),
            path: "/Book.cbz",
            title: "Book",
            openedAt: Date(),
            bookmarkData: Data(),
            isDirectory: false
        )
        #expect(item.iconName == "book.closed")
    }
}

// MARK: - ReadingDirection

struct ReadingDirectionTests {
    @Test func leftToRightIsNotRTL() {
        #expect(ReadingDirection.leftToRight.isRTL == false)
    }

    @Test func rightToLeftIsRTL() {
        #expect(ReadingDirection.rightToLeft.isRTL == true)
    }

    @Test func rawValuesRoundTrip() {
        for direction in ReadingDirection.allCases {
            let restored = ReadingDirection(rawValue: direction.rawValue)
            #expect(restored == direction)
        }
    }
}

// MARK: - FileNode

struct FileNodeTests {
    @Test func folderKindUsesFolderIcon() {
        let url = URL(fileURLWithPath: "/Library")
        let node = FileNode(id: url, url: url, name: "Library", kind: .folder, children: nil)
        #expect(node.iconName == "folder")
    }

    @Test func archiveKindUsesBookIcon() {
        let url = URL(fileURLWithPath: "/Book.cbz")
        let node = FileNode(id: url, url: url, name: "Book", kind: .archive, children: nil)
        #expect(node.iconName == "book.closed")
    }
}

// MARK: - Layout and Fit enums

struct PageLayoutTests {
    @Test func rawValuesAreStable() {
        #expect(PageLayout.single.rawValue == "single")
        #expect(PageLayout.double.rawValue == "double")
        #expect(PageLayout.vertical.rawValue == "vertical")
    }
}

struct FitModeTests {
    @Test func rawValuesAreStable() {
        #expect(FitMode.fitScreen.rawValue == "fitScreen")
        #expect(FitMode.fitWidth.rawValue == "fitWidth")
    }
}

// MARK: - Loader supported extensions (pure config)

struct LoaderExtensionTests {
    @Test func folderLoaderSupportsCommonImageFormats() {
        let exts = FolderLoader.supportedExtensions
        #expect(exts.contains("jpg"))
        #expect(exts.contains("png"))
        #expect(exts.contains("webp"))
        #expect(exts.contains("heic"))
        #expect(exts.contains("gif"))
    }

    @Test func cbzLoaderSupportsArchiveExtensions() {
        let exts = CBZLoader.supportedExtensions
        #expect(exts.contains("cbz"))
        #expect(exts.contains("zip"))
    }
}

// MARK: - Natural sort behaviour (foundation contract Panely relies on)

struct NaturalSortTests {
    @Test func numericSegmentsSortNumerically() {
        let names = ["10.cbz", "2.cbz", "1.cbz", "20.cbz"]
        let sorted = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #expect(sorted == ["1.cbz", "2.cbz", "10.cbz", "20.cbz"])
    }

    @Test func mixedPrefixSortedLexicallyAcrossPrefix() {
        let names = ["Vol 10.cbz", "Vol 2.cbz", "Vol 1.cbz"]
        let sorted = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #expect(sorted == ["Vol 1.cbz", "Vol 2.cbz", "Vol 10.cbz"])
    }
}

// MARK: - PositionKey (stable key across temp extractions)

struct PositionKeyTests {
    @Test func directOpenReturnsPlainPath() {
        let url = URL(fileURLWithPath: "/Comics/Vol01.cbz")
        let key = PositionKey.make(for: url, opened: nil, tempRoot: nil)
        #expect(key == "/Comics/Vol01.cbz")
    }

    @Test func tempBackedVolumeUsesCompoundKey() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-A/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/series.zip#Vol01.cbz")
    }

    @Test func tempRootMatchesOpenedPathDirectly() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")

        let key = PositionKey.make(for: temp, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/series.zip")
    }

    @Test func outsideTempFallsBackToSourcePath() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/other/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/other/Vol01.cbz")
    }

    @Test func deeplyNestedPathProducesRelativeSegments() {
        let opened = URL(fileURLWithPath: "/Comics/super.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-A/middle/Vol01")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/super.zip#middle/Vol01")
    }

    @Test func siblingPathWithSimilarPrefixIsNotCollapsed() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-Abc/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/tmp/panely-Abc/Vol01.cbz")
    }
}

// MARK: - FolderLoader integration (real temp directories)

struct FolderLoaderIntegrationTests {
    @Test func filtersOutNonImageFiles() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("page1.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("page2.png"))
        try Fixture.writeFile(dir.appendingPathComponent("readme.txt"))
        try Fixture.writeFile(dir.appendingPathComponent("config.json"))

        let source = try FolderLoader.load(from: dir)
        let names = Set(source.pages.map(\.displayName))
        #expect(names == ["page1.jpg", "page2.png"])
    }

    @Test func naturalSortsByFilename() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("page10.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("page2.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("page1.jpg"))

        let source = try FolderLoader.load(from: dir)
        let names = source.pages.map(\.displayName)
        #expect(names == ["page1.jpg", "page2.jpg", "page10.jpg"])
    }

    @Test func skipsHiddenFiles() throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("001.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent(".DS_Store"))
        try Fixture.writeFile(dir.appendingPathComponent("._thumbnail.jpg"))

        let source = try FolderLoader.load(from: dir)
        let names = source.pages.map(\.displayName)
        #expect(names.contains("001.jpg"))
        #expect(!names.contains(".DS_Store"))
    }

    @Test func titleDerivedFromFolderName() throws {
        let parent = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: parent) }

        let dir = parent.appendingPathComponent("OnePiece", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Fixture.writeFile(dir.appendingPathComponent("001.jpg"))

        let source = try FolderLoader.load(from: dir)
        #expect(source.title == "OnePiece")
    }
}

// MARK: - FileNode.loadTree

struct FileNodeLoadTests {
    @Test func includesArchivesAndSubfoldersButNotLooseImages() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("cover.jpg"))
        try Fixture.writeFile(dir.appendingPathComponent("vol01.cbz"))
        let sub = dir.appendingPathComponent("vol02", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Fixture.writeFile(sub.appendingPathComponent("001.jpg"))

        let nodes = await FileNode.loadTree(from: dir, maxDepth: 2)
        let names = nodes.map(\.name)

        #expect(!names.contains("cover.jpg"))
        #expect(names.contains("vol01"))
        #expect(names.contains("vol02"))
    }

    @Test func returnsEmptyForNonExistentDirectory() async {
        let url = URL(fileURLWithPath: "/__panely_definitely_missing_\(UUID().uuidString)")
        let nodes = await FileNode.loadTree(from: url)
        #expect(nodes.isEmpty)
    }

    @Test func sortsAlphanumericallyWithNaturalOrder() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try Fixture.writeFile(dir.appendingPathComponent("Vol 10.cbz"))
        try Fixture.writeFile(dir.appendingPathComponent("Vol 1.cbz"))
        try Fixture.writeFile(dir.appendingPathComponent("Vol 2.cbz"))

        let nodes = await FileNode.loadTree(from: dir, maxDepth: 1)
        #expect(nodes.map(\.name) == ["Vol 1", "Vol 2", "Vol 10"])
    }
}

// MARK: - CBZLoader integration (with real zip fixtures)

struct CBZLoaderIntegrationTests {
    @Test func hasNestedArchivesFalseForFlatArchive() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let src = try Fixture.makeTempDir()
        try Fixture.writeFile(src.appendingPathComponent("001.jpg"))
        try Fixture.writeFile(src.appendingPathComponent("002.jpg"))

        let zipURL = workDir.appendingPathComponent("book.cbz")
        try Fixture.zipDirectory(src, to: zipURL)
        try? FileManager.default.removeItem(at: src)

        let hasNested = try await CBZLoader.hasNestedArchives(at: zipURL)
        #expect(hasNested == false)
    }

    @Test func hasNestedArchivesTrueWhenInnerCBZPresent() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Build inner archive
        let innerSrc = try Fixture.makeTempDir()
        try Fixture.writeFile(innerSrc.appendingPathComponent("001.jpg"))
        let innerZip = workDir.appendingPathComponent("_inner_scratch.cbz")
        try Fixture.zipDirectory(innerSrc, to: innerZip)
        try? FileManager.default.removeItem(at: innerSrc)

        // Outer that contains the inner archive
        let outerSrc = try Fixture.makeTempDir()
        try FileManager.default.moveItem(at: innerZip, to: outerSrc.appendingPathComponent("vol01.cbz"))
        let outerZip = workDir.appendingPathComponent("series.cbz")
        try Fixture.zipDirectory(outerSrc, to: outerZip)
        try? FileManager.default.removeItem(at: outerSrc)

        let hasNested = try await CBZLoader.hasNestedArchives(at: outerZip)
        #expect(hasNested == true)
    }

    @Test func loadProducesNaturallySortedPages() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let src = try Fixture.makeTempDir()
        try Fixture.writeFile(src.appendingPathComponent("10.jpg"))
        try Fixture.writeFile(src.appendingPathComponent("02.jpg"))
        try Fixture.writeFile(src.appendingPathComponent("01.jpg"))

        let zipURL = workDir.appendingPathComponent("book.cbz")
        try Fixture.zipDirectory(src, to: zipURL)
        try? FileManager.default.removeItem(at: src)

        let comic = try await CBZLoader.load(from: zipURL)
        #expect(comic.pages.map(\.displayName) == ["01.jpg", "02.jpg", "10.jpg"])
    }

    @Test func extractAllRecursivelyUnpacksNestedArchives() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        // Inner archive with images
        let innerSrc = try Fixture.makeTempDir()
        try Fixture.writeFile(innerSrc.appendingPathComponent("p1.jpg"))
        let innerZip = workDir.appendingPathComponent("_inner_scratch.cbz")
        try Fixture.zipDirectory(innerSrc, to: innerZip)
        try? FileManager.default.removeItem(at: innerSrc)

        // Outer archive containing the inner archive
        let outerSrc = try Fixture.makeTempDir()
        try FileManager.default.moveItem(at: innerZip, to: outerSrc.appendingPathComponent("vol01.cbz"))
        let outerZip = workDir.appendingPathComponent("series.zip")
        try Fixture.zipDirectory(outerSrc, to: outerZip)
        try? FileManager.default.removeItem(at: outerSrc)

        let dest = workDir.appendingPathComponent("extracted", isDirectory: true)
        try await CBZLoader.extractAll(from: outerZip, to: dest)

        // After recursive extraction: dest/vol01/ folder exists with p1.jpg inside
        var isDir: ObjCBool = false
        let volDir = dest.appendingPathComponent("vol01")
        #expect(FileManager.default.fileExists(atPath: volDir.path, isDirectory: &isDir))
        #expect(isDir.boolValue == true)

        let innerImg = volDir.appendingPathComponent("p1.jpg")
        #expect(FileManager.default.fileExists(atPath: innerImg.path))

        // The original nested archive file should have been removed after extraction
        let residualZip = dest.appendingPathComponent("vol01.cbz")
        #expect(!FileManager.default.fileExists(atPath: residualZip.path))
    }
}

// MARK: - FitCalculator (pure math for fit-to-screen / fit-to-width)

struct FitCalculatorTests {
    @Test func fitScreenPicksMinRatioForPortraitDocument() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 1000, height: 1500),
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitScreen
        )
        // min(800/1000, 600/1500) = min(0.8, 0.4) = 0.4
        #expect(abs(mag - 0.4) < 0.0001)
    }

    @Test func fitScreenPicksMinRatioForLandscapeDocument() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 2000, height: 1000),
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitScreen
        )
        // min(800/2000, 600/1000) = min(0.4, 0.6) = 0.4
        #expect(abs(mag - 0.4) < 0.0001)
    }

    @Test func fitWidthUsesWidthRatio() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 1000, height: 1500),
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitWidth
        )
        #expect(abs(mag - 0.8) < 0.0001)
    }

    @Test func zeroViewportFallsBackToIdentity() {
        let mag = FitCalculator.magnification(
            docSize: CGSize(width: 1000, height: 1500),
            viewport: .zero,
            fitMode: .fitScreen
        )
        #expect(mag == 1.0)
    }

    @Test func zeroDocumentFallsBackToIdentity() {
        let mag = FitCalculator.magnification(
            docSize: .zero,
            viewport: CGSize(width: 800, height: 600),
            fitMode: .fitScreen
        )
        #expect(mag == 1.0)
    }

    @Test func calculationIsIdempotentOnRepeatedCalls() {
        let doc = CGSize(width: 1200, height: 1800)
        let viewport = CGSize(width: 900, height: 700)

        let a = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)
        let b = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)
        #expect(a == b)
    }

    @Test func toggleBetweenModesProducesDistinctAndStableValues() {
        let doc = CGSize(width: 1000, height: 1500)
        let viewport = CGSize(width: 800, height: 600)

        let screenA = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)
        let width = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitWidth)
        let screenB = FitCalculator.magnification(docSize: doc, viewport: viewport, fitMode: .fitScreen)

        #expect(screenA != width)
        #expect(screenA == screenB)  // toggling back gives identical value
    }
}

// MARK: - NSScrollView fit-magnification stability (integration)

@MainActor
struct FitMagnificationStabilityTests {
    /// Core bug contract: viewport must be derived from a property that is
    /// invariant to the scroll view's current magnification. `contentSize`
    /// qualifies; `contentView.bounds.size` does not (it is document-space
    /// and scales inversely with magnification).
    @Test func contentSizeIsInvariantToMagnificationWhileBoundsIsNot() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        scrollView.magnification = 1.0
        scrollView.layoutSubtreeIfNeeded()
        let sizeAt1 = scrollView.contentSize
        let boundsAt1 = scrollView.contentView.bounds.size

        scrollView.magnification = 0.3
        scrollView.layoutSubtreeIfNeeded()
        let sizeAt03 = scrollView.contentSize
        let boundsAt03 = scrollView.contentView.bounds.size

        // contentSize holds the physical viewport dimensions — stable.
        #expect(abs(sizeAt1.width - sizeAt03.width) < 1.0)
        #expect(abs(sizeAt1.height - sizeAt03.height) < 1.0)

        // bounds is document-space and expands as magnification shrinks.
        #expect(boundsAt03.width > boundsAt1.width * 1.5)
    }

    /// Toggling fit modes repeatedly must produce stable magnifications.
    /// This regresses the bug where fit was computed from
    /// `contentView.bounds.size`, causing a feedback loop where each toggle
    /// produced a different magnification than the previous occurrence of
    /// that same fit mode.
    @Test func fitScreenToFitWidthBackToFitScreenIsStable() {
        let scrollView = Self.makeScrollView(size: CGSize(width: 800, height: 600))
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1500))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        func applyFit(_ mode: FitMode) -> CGFloat {
            let fit = FitCalculator.magnification(
                docSize: doc.frame.size,
                viewport: scrollView.contentSize,
                fitMode: mode
            )
            scrollView.magnification = fit
            scrollView.layoutSubtreeIfNeeded()
            return fit
        }

        let firstFitScreen = applyFit(.fitScreen)
        let fitWidth = applyFit(.fitWidth)
        let secondFitScreen = applyFit(.fitScreen)
        let thirdFitScreen = applyFit(.fitScreen)
        let secondFitWidth = applyFit(.fitWidth)

        // Fit Screen values stay identical no matter how many toggles occurred
        #expect(abs(firstFitScreen - secondFitScreen) < 0.001)
        #expect(abs(firstFitScreen - thirdFitScreen) < 0.001)

        // Fit Width values stay identical as well
        #expect(abs(fitWidth - secondFitWidth) < 0.001)

        // And the two modes remain distinct
        #expect(abs(firstFitScreen - fitWidth) > 0.1)
    }

    private static func makeScrollView(size: CGSize) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 10.0
        scrollView.scrollerStyle = .overlay
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        return scrollView
    }
}

// MARK: - CenteringClipView (keeps the page centered when the viewport is larger)

@MainActor
struct CenteringClipViewTests {
    @Test func centersBothAxesWhenDocumentIsSmaller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.contentView = CenteringClipView()
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let bounds = scrollView.contentView.bounds
        // Document (400x300) centered in clip bounds (800x600).
        // Expected origin = docMid - clipSize/2 = (200-400, 150-300) = (-200, -150)
        #expect(abs(bounds.origin.x - (-200)) < 1.0)
        #expect(abs(bounds.origin.y - (-150)) < 1.0)
    }

    @Test func centersOnlyOnTheAxisWhereDocumentIsSmaller() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.contentView = CenteringClipView()
        // Document is narrower than clip (400 < 800) but taller than clip (900 > 600)
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 900))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let bounds = scrollView.contentView.bounds
        // Horizontal centering: origin.x = 200 - 400 = -200
        #expect(abs(bounds.origin.x - (-200)) < 1.0)
        // Vertical: super's constrain keeps origin.y >= 0 (document scrollable)
        #expect(bounds.origin.y >= 0)
    }

    @Test func doesNotCenterWhenDocumentIsLargerThanClip() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        scrollView.contentView = CenteringClipView()
        let doc = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        scrollView.documentView = doc
        scrollView.layoutSubtreeIfNeeded()

        let bounds = scrollView.contentView.bounds
        // Both axes larger in doc → no centering offset, origin stays at default (>= 0)
        #expect(bounds.origin.x >= 0)
        #expect(bounds.origin.y >= 0)
    }
}
