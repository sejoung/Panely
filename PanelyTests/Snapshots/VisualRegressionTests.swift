import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Panely

/// Renders a set of screens and compares each with its checked-in reference
/// (`PanelyTests/Snapshots/Reference/reference-*.png`) via
/// `SnapshotComparator`, so a layout regression — a section missing, rows
/// drawn flat, a control gone — fails the normal test run.
///
/// Only screens without clocks, version strings or other run-dependent
/// content are covered. Font rendering changes between macOS major versions,
/// so the suite runs only on the major version the references were recorded
/// on (`reference-snapshots.json`) and is skipped elsewhere.
///
/// On a failure the rendered image and a diff (differences in red) are
/// written to the Debug app sandbox's `Caches/panely-visual-diffs/`; the
/// failure message has the paths. After an intended UI change, re-record
/// with `scripts/update-reference-snapshots.sh` and review the new PNGs in
/// the diff before committing them.
@MainActor
@Suite(
    "Visual Regression",
    .enabled(if: VisualRegressionGate.isEnabled, "visual tier (scripts/test-visual.sh), on the references' macOS version")
)
struct VisualRegressionTests {

    @Test func sidebarPopulated() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.sidebarPopulatedViewModel(library: library)
        try await check(SidebarHost(requestFocus: {}).environment(vm),
                        size: SnapshotRenderer.sidebarSize,
                        named: "sidebar-populated",
                        outlineRows: 13)
    }

    @Test func sidebarEmpty() async throws {
        let vm = SnapshotSampleContent.emptyViewModel()
        try await check(SidebarHost(requestFocus: {}).environment(vm),
                        size: SnapshotRenderer.sidebarSize,
                        named: "sidebar-empty")
    }

    @Test func readerSinglePage() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .single,
            sidebarPinned: true,
            library: library
        )
        try await check(MockReaderScene().environment(vm),
                        size: SnapshotRenderer.heroSize,
                        named: "reader-single-page",
                        outlineRows: Self.libraryFilesRows)
    }

    @Test func toolbarLoaded() async throws {
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            fitMode: .fitWidth,
            sidebarPinned: true
        )
        try await check(
            ReaderToolbarOverlay(shown: true)
                .environment(vm)
                .environment(ViewerController())
                .padding(PanelySpacing.md),
            size: SnapshotRenderer.toolbarSize,
            named: "toolbar-loaded"
        )
    }

    @Test func endOfVolumeCard() async throws {
        let vm = SnapshotSampleContent.atLastPageViewModel()
        try await check(
            ZStack {
                Color.black
                EndOfVolumeCardOverlay(requestFocus: {})
                    .environment(vm)
            },
            size: SnapshotRenderer.cardSize,
            named: "end-of-volume-card"
        )
    }

    @Test func translationReading() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        try await check(MockReaderScene().environment(vm),
                        size: SnapshotRenderer.heroSize,
                        named: "translation-reading")
    }

    @Test func translationPanel() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        try await check(
            VStack {
                TranslationPanel()
                    .environment(vm)
                    .background(PanelyColor.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelyColor.bgPrimary),
            size: CGSize(width: 380, height: 352),
            named: "translation-panel",
            // The language-pack status line ("Checking the language
            // pack…", then the result) depends on when it's caught.
            ignoring: [CGRect(x: 28, y: 88, width: 330, height: 22)]
        )
    }

    /// The Files section of `LibraryFixture` with the open book's folder
    /// expanded: header, One-shots, Series A and its three volumes, Series B.
    private static let libraryFilesRows = 7

    // MARK: - Reader layouts

    @Test func readerDoublePage() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            fitMode: .fitWidth,
            sidebarPinned: true,
            pageIndex: 4,
            library: library
        )
        try await check(MockReaderScene().environment(vm),
                        size: SnapshotRenderer.heroSize,
                        named: "reader-double-page",
                        outlineRows: Self.libraryFilesRows)
    }

    /// Right to left: the spread's pages swap sides and the direction
    /// button turns around.
    @Test func readerRightToLeftDouble() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            direction: .rightToLeft,
            sidebarPinned: true,
            pageIndex: 6,
            library: library
        )
        try await check(MockReaderScene().environment(vm),
                        size: SnapshotRenderer.heroSize,
                        named: "reader-rtl-double",
                        outlineRows: Self.libraryFilesRows)
    }

    @Test func readerVerticalStrip() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .vertical,
            fitMode: .fitWidth,
            pageCount: 12,
            library: library
        )
        try await check(MockReaderScene().environment(vm),
                        size: SnapshotRenderer.heroSize,
                        named: "reader-vertical-strip")
    }

    // MARK: - Reader chrome

    /// The translated toolbar: translate button lit, "English ▾" beside it.
    @Test func toolbarTranslated() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        try await check(
            ReaderToolbarOverlay(shown: true)
                .environment(vm)
                .environment(ViewerController())
                .padding(PanelySpacing.md),
            size: SnapshotRenderer.toolbarSize,
            named: "toolbar-translated"
        )
    }

    @Test func sliderOverlay() async throws {
        let vm = SnapshotSampleContent.loadedViewModel(layout: .double, pageIndex: 10, pageCount: 24)
        try await check(
            ZStack {
                Color.black
                ReaderSliderOverlay(shown: true)
                    .environment(vm)
            },
            size: CGSize(width: 720, height: 120),
            named: "slider-overlay"
        )
    }

    /// Page thumbnails (decoded from real image files), the current page
    /// outlined, a translated page badged.
    @Test func thumbnailSidebar() async throws {
        let dir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pages = try (1...4).map { number -> ComicPage in
            let image = SnapshotSampleContent.makeSamplePage(number: number, of: 4)
            let url = dir.appendingPathComponent("page-\(number).png")
            let png = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:))?
                .representation(using: .png, properties: [:]))
            try png.write(to: url)
            return ComicPage(source: .file(url), displayName: "page-\(number)")
        }
        let vm = SnapshotSampleContent.loadedViewModel(thumbnailSidebarVisible: true, pageIndex: 1, pageCount: 4)
        vm.appLanguage = .english
        vm.translationTargetLanguage = .english
        vm.translationEnabled = true
        vm.source = ComicSource(title: "Sample Volume 1", pages: pages)
        vm.currentPageIndex = 1
        try await waitUntil { vm.translation.bookPageCount == pages.count }
        try vm.translationManager.store.save(
            TranslationSnapshotContent.translated(TranslationSnapshotContent.pages[0]),
            key: TranslationStore.key(pageID: pages[0].id, from: .japanese, to: .english)
        )
        vm.translation.setSource(.japanese)
        try await waitUntil { vm.translatedPageIndices == [0] }

        try await check(
            ThumbnailSidebarHost(requestFocus: {}).environment(vm),
            size: CGSize(width: 148, height: 720),
            named: "thumbnail-sidebar"
        )
    }

    @Test func previousVolumeCard() async throws {
        let vm = SnapshotSampleContent.atFirstPageWithPrevCueViewModel()
        try await check(
            ZStack {
                Color.black
                PreviousVolumeCardOverlay(requestFocus: {})
                    .environment(vm)
            },
            size: SnapshotRenderer.cardSize,
            named: "previous-volume-card"
        )
    }

    /// The spinner animates, so the frame it's caught on is left out.
    @Test func loadingOverlay() async throws {
        try await check(
            ZStack {
                Color.black
                LoadingOverlay(message: "Extracting archive…")
            },
            size: SnapshotRenderer.overlaySize,
            named: "loading-overlay",
            ignoring: [CGRect(x: 88, y: 48, width: 44, height: 44)]
        )
    }

    // MARK: - Translation editing

    /// The edit bar with one balloon hidden and one corrected: "2 edited",
    /// the "1 Hidden" menu and "Revert This Book…".
    @Test func translationEditBar() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        vm.setEditingTranslations(true)
        let page = vm.source.pages[0]
        let bubbles = try #require(vm.translation.pages[page.id]?.bubbles)
        vm.translationEdits.hide(pageID: page.id, bubble: bubbles[1])
        vm.translationEdits.update(pageID: page.id, bubble: bubbles[2]) {
            $0.translations[TranslationLanguage.english.rawValue] = "Finally, you're awake."
        }
        try await check(
            ZStack {
                Color.black
                TranslationEditBar().environment(vm)
            },
            size: CGSize(width: 820, height: 80),
            named: "translation-edit-bar"
        )
    }

    @Test func translationBalloonPopover() async throws {
        try await check(
            VStack {
                TranslationBubblePopover(
                    source: "やっと目が覚めたね",
                    translation: "You're finally awake.",
                    alternates: [.korean: "드디어 깼구나."],
                    onEdit: { _ in }
                )
                .background(PanelyColor.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelyColor.bgPrimary),
            size: CGSize(width: 340, height: 205),
            named: "translation-balloon-popover"
        )
    }

    // MARK: - Settings

    @Test func generalSettings() async throws {
        let vm = SnapshotSampleContent.emptyViewModel()
        vm.appLanguage = .english
        try await check(
            ZStack {
                PanelyColor.bgPrimary
                GeneralSettingsView(viewModel: vm)
            },
            size: SnapshotRenderer.settingsSize,
            named: "settings-general"
        )
    }

    /// A remembered folder: the toggle, "Last opened" (home-relative, so the
    /// same on every machine) and "Forget Now".
    @Test func librarySettings() async throws {
        let vm = SnapshotSampleContent.emptyViewModel()
        vm.lastLibraryRoot.save(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Comics/Sample Library", isDirectory: true)
        )
        try await check(
            ZStack {
                PanelyColor.bgPrimary
                LibrarySettingsView(viewModel: vm)
            },
            size: SnapshotRenderer.settingsSize,
            named: "settings-library"
        )
    }

    /// Fixed cache contents, but the sizes are formatted in the machine's
    /// locale (`ByteCountFormatter`), so their column is left out.
    @Test func storageSettings() async throws {
        let cacheRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let active = cacheRoot.appendingPathComponent("active-book", isDirectory: true)
        let clearable = cacheRoot.appendingPathComponent("old-book", isDirectory: true)
        for (dir, bytes) in [(active, 1_400_000), (clearable, 900_000)] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 0xAB, count: bytes).write(to: dir.appendingPathComponent("pages.bin"))
        }
        let vm = SnapshotSampleContent.loadedViewModel()
        vm.tempDir.url = active
        try await check(
            ZStack {
                PanelyColor.bgPrimary
                StorageSettingsView(viewModel: vm, cacheRoot: cacheRoot)
            },
            size: SnapshotRenderer.settingsSize,
            named: "settings-storage",
            ignoring: [Self.storageSizesColumn]
        )
    }

    /// The right-hand values of the storage form's three size rows.
    private static let storageSizesColumn = CGRect(x: 420, y: 60, width: 80, height: 110)

    // MARK: - Helpers

    /// `ignoring`: regions, in points, left out of the comparison — for
    /// content that depends on the machine rather than the layout.
    ///
    /// `outlineRows`: for a screen with the library sidebar, the rows its
    /// outline shows once the tree has loaded. The tree loads in two passes;
    /// with many suites sharing the main actor a fixed wait sometimes caught
    /// it between them (Series A still collapsed), so wait for the rows.
    private func check<V: View>(
        _ view: V,
        size: CGSize,
        named name: String,
        outlineRows: Int? = nil,
        ignoring masks: [CGRect] = []
    ) async throws {
        // Every screen in English: `TranslationSnapshotContent` switches the
        // app language globally, so leaving it to chance would make the
        // other screens depend on test order.
        AppLocalization.shared.apply(.english)
        let scale = SnapshotRenderer.renderScale
        let pixelMasks = masks.map {
            CGRect(x: $0.minX * scale, y: $0.minY * scale, width: $0.width * scale, height: $0.height * scale)
        }
        let actual = try await render(
            view.environment(\.locale, Locale(identifier: "en")),
            size: size,
            outlineRows: outlineRows,
            ignoring: pixelMasks
        )

        if VisualRegressionGate.isRecording {
            let url = try VisualRegressionGate.recordingDirectory()
                .appendingPathComponent("reference-\(name).png")
            try actual.write(to: url)
            print("📸 recorded \(url.path)")
            return
        }

        guard let reference = VisualRegressionGate.reference(named: name) else {
            Issue.record("No reference for \(name). Record one with scripts/update-reference-snapshots.sh.")
            return
        }
        // Off the main actor, so the other screens keep rendering meanwhile.
        let result = try await Task.detached {
            try SnapshotComparator.compare(actual: actual, reference: reference, ignoring: pixelMasks)
        }.value
        guard result.differingFraction > SnapshotComparator.defaultMaxDifferingFraction else { return }

        let dir = try VisualRegressionGate.diffDirectory()
        let actualURL = dir.appendingPathComponent("\(name)-actual.png")
        let diffURL = dir.appendingPathComponent("\(name)-diff.png")
        try actual.write(to: actualURL)
        try result.diffPNG?.write(to: diffURL)
        Issue.record("""
            \(name) differs from its reference in \(result.differingPixels) of \(result.comparedPixels) px \
            (\(String(format: "%.2f", result.differingFraction * 100))%, budget \
            \(String(format: "%.2f", SnapshotComparator.defaultMaxDifferingFraction * 100))%).
            Rendered: \(actualURL.path)
            Diff:     \(diffURL.path)
            If the change is intended, re-record with scripts/update-reference-snapshots.sh.
            """)
    }

    /// The screen once it has settled: the usual fixed wait, then (for a
    /// sidebar) its tree loaded, then until two captures a beat apart match
    /// outside `masks` — thumbnails decode and caches load asynchronously,
    /// and slower under a full test run.
    private func render<V: View>(
        _ view: V,
        size: CGSize,
        outlineRows: Int?,
        ignoring masks: [CGRect]
    ) async throws -> Data {
        let hosted = await SnapshotRenderer.host(view, size: size)
        defer { hosted.close() }
        try await Task.sleep(for: .seconds(SnapshotRenderer.settleSeconds))
        if let outlineRows {
            try await hosted.settle("the sidebar's tree to load (\(outlineRows) rows)", timeout: .seconds(20)) {
                hosted.firstSubview(of: NSOutlineView.self)?.numberOfRows == outlineRows
            }
        }
        var previous = try hosted.pngData()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(250))
            let current = try hosted.pngData()
            let changed = try await Task.detached { [previous] in
                try SnapshotComparator.compare(actual: current, reference: previous, ignoring: masks).differingPixels
            }.value
            if changed == 0 { return current }
            previous = current
        }
        return previous
    }
}

/// Where references come from and whether this machine can use them.
enum VisualRegressionGate {
    /// Recording mode, set by `scripts/update-reference-snapshots.sh`: render
    /// and write new references instead of comparing. An environment
    /// variable (passed as `TEST_RUNNER_PANELY_RECORD_REFERENCE_SNAPSHOTS`,
    /// which xcodebuild hands the test process without the prefix), so it
    /// reaches only that run — not other test runs sharing the Debug sandbox.
    static var isRecording: Bool {
        ProcessInfo.processInfo.environment["PANELY_RECORD_REFERENCE_SNAPSHOTS"] == "1"
    }

    /// Opt-in (`scripts/test-visual.sh`, or recording), and only on the
    /// macOS major version the references were recorded on.
    static var isEnabled: Bool {
        if isRecording { return true }
        guard TestTier.visual else { return false }
        guard let url = bundle.url(forResource: "reference-snapshots", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return false }
        return manifest.macOSMajorVersion == ProcessInfo.processInfo.operatingSystemVersion.majorVersion
    }

    static func reference(named name: String) -> Data? {
        bundle.url(forResource: "reference-\(name)", withExtension: "png")
            .flatMap { try? Data(contentsOf: $0) }
    }

    /// Recorded references plus their manifest, staged in the sandbox for
    /// the script to copy into the repo.
    static func recordingDirectory() throws -> URL {
        let dir = try cachesSubdirectory("panely-reference-snapshots")
        let manifest = Manifest(macOSMajorVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion)
        try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("reference-snapshots.json"))
        return dir
    }

    static func diffDirectory() throws -> URL {
        try cachesSubdirectory("panely-visual-diffs")
    }

    private struct Manifest: Codable {
        let macOSMajorVersion: Int
    }

    private final class BundleToken {}

    private static var bundle: Bundle { Bundle(for: BundleToken.self) }

    private static func cachesSubdirectory(_ name: String) throws -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
