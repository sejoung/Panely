import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Generates `docs/screenshots/*.png` for the user manual.
///
/// The tests stage PNGs in the Debug app sandbox. Regenerate the checked-in
/// manual screenshots via `scripts/generate-snapshots.sh`.
/// Register each scenario and its outputs in `scripts/manual-snapshots.json`;
/// use `--list` / `--only <id>` to find and regenerate individual scenarios.
@MainActor
@Suite(
    "Manual Snapshots",
    .serialized,
    .enabled(if: SnapshotGenerationGate.isEnabled)
)
struct SnapshotGalleryTests {

    // MARK: - Hero (full reader composition)

    @Test func heroSinglePage() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .single,
            sidebarPinned: true,
            library: library
        )
        try await render(MockReaderScene().environment(vm),
                   size: SnapshotRenderer.heroSize,
                   named: "01-hero-single-page.png")
    }

    @Test func heroDoublePage() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            fitMode: .fitWidth,
            sidebarPinned: true,
            pageIndex: 4,
            library: library
        )
        try await render(MockReaderScene().environment(vm),
                   size: SnapshotRenderer.heroSize,
                   named: "02-hero-double-page.png")
    }

    @Test func heroVerticalStrip() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .vertical,
            fitMode: .fitWidth,
            sidebarPinned: false,
            pageCount: 12,
            library: library
        )
        try await render(MockReaderScene().environment(vm),
                   size: SnapshotRenderer.heroSize,
                   named: "03-hero-vertical-strip.png")
    }

    @Test func heroRightToLeft() async throws {
        let library = try LibraryFixture()
        // 만화 친화 RTL double-page. Toolbar shows direction toggle in RTL.
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            direction: .rightToLeft,
            sidebarPinned: true,
            pageIndex: 6,
            library: library
        )
        try await render(MockReaderScene().environment(vm),
                   size: SnapshotRenderer.heroSize,
                   named: "04-hero-rtl-manga.png")
    }

    // MARK: - Library sidebar variations

    @Test func sidebarWithFavoritesAndBookmarks() async throws {
        let library = try LibraryFixture()
        let vm = SnapshotSampleContent.sidebarPopulatedViewModel(library: library)
        try await render(SidebarHost(requestFocus: {}).environment(vm),
                   size: SnapshotRenderer.sidebarSize,
                   named: "05-sidebar-populated.png")
    }

    @Test func sidebarEmptyState() async throws {
        let vm = SnapshotSampleContent.emptyViewModel()
        try await render(SidebarHost(requestFocus: {}).environment(vm),
                   size: SnapshotRenderer.sidebarSize,
                   named: "06-sidebar-empty.png")
    }

    // MARK: - Toolbar

    @Test func toolbarLoaded() async throws {
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            fitMode: .fitWidth,
            sidebarPinned: true
        )
        let viewer = ViewerController()
        try await render(
            ReaderToolbarOverlay(shown: true)
                .environment(vm)
                .environment(viewer)
                .padding(PanelySpacing.md),
            size: SnapshotRenderer.toolbarSize,
            named: "07-toolbar-loaded.png"
        )
    }

    @Test func toolbarSpreadOffset() async throws {
        // Double-page with the standalone-cover offset enabled, so the manual
        // shows the (double-mode-only) offset toggle in its active state.
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            fitMode: .fitWidth,
            sidebarPinned: true,
            coverAlone: true
        )
        let viewer = ViewerController()
        try await render(
            ReaderToolbarOverlay(shown: true)
                .environment(vm)
                .environment(viewer)
                .padding(PanelySpacing.md),
            size: SnapshotRenderer.toolbarSize,
            named: "14-toolbar-spread-offset.png"
        )
    }

    // MARK: - Overlays

    @Test func endOfVolumeCard() async throws {
        let vm = SnapshotSampleContent.atLastPageViewModel()
        try await render(
            ZStack {
                Color.black
                EndOfVolumeCardOverlay(requestFocus: {})
                    .environment(vm)
            },
            size: SnapshotRenderer.cardSize,
            named: "08-end-of-volume-card.png"
        )
    }

    @Test func previousVolumeCard() async throws {
        let vm = SnapshotSampleContent.atFirstPageWithPrevCueViewModel()
        try await render(
            ZStack {
                Color.black
                PreviousVolumeCardOverlay(requestFocus: {})
                    .environment(vm)
            },
            size: SnapshotRenderer.cardSize,
            named: "09-previous-volume-card.png"
        )
    }

    @Test func loadingOverlay() async throws {
        try await render(
            ZStack {
                Color.black
                LoadingOverlay(message: "Extracting archive…")
            },
            size: SnapshotRenderer.overlaySize,
            named: "10-loading-overlay.png"
        )
    }

    // MARK: - Slider + quick-jump

    @Test func sliderAndQuickJump() async throws {
        let vm = SnapshotSampleContent.loadedViewModel(
            layout: .double,
            pageIndex: 10,
            pageCount: 24
        )
        try await render(
            ZStack {
                Color.black
                ReaderSliderOverlay(shown: true)
                    .environment(vm)
            },
            size: CGSize(width: 720, height: 120),
            named: "11-slider-quickjump.png"
        )
    }

    // MARK: - Settings

    @Test func storageCacheSettings() async throws {
        let cacheRoot = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let active = cacheRoot.appendingPathComponent("active-book", isDirectory: true)
        let clearable = cacheRoot.appendingPathComponent("old-book", isDirectory: true)
        try writeCacheEntry(active, byteCount: 1_400_000)
        try writeCacheEntry(clearable, byteCount: 900_000)

        let vm = SnapshotSampleContent.loadedViewModel()
        vm.tempDir.url = active

        try await render(
            ZStack {
                PanelyColor.bgPrimary
                StorageSettingsView(viewModel: vm, cacheRoot: cacheRoot)
            },
            size: SnapshotRenderer.settingsSize,
            named: "12-storage-cache.png"
        )
    }

    @Test func generalSettings() async throws {
        let vm = SnapshotSampleContent.emptyViewModel()
        vm.appLanguage = .english

        try await render(
            ZStack {
                PanelyColor.bgPrimary
                GeneralSettingsView(viewModel: vm)
            },
            size: SnapshotRenderer.settingsSize,
            named: "16-general-settings.png"
        )
    }

    @Test func librarySettings() async throws {
        let vm = SnapshotSampleContent.emptyViewModel()
        // Seed a remembered folder so the shot shows the populated state —
        // the toggle, the "Last opened" path, and the Forget button. The
        // snapshot viewmodel uses the test bookmark resolver, so save/peek
        // round-trip without a real security scope.
        vm.lastLibraryRoot.save(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Comics/Sample Library", isDirectory: true)
        )

        try await render(
            ZStack {
                PanelyColor.bgPrimary
                LibrarySettingsView(viewModel: vm)
            },
            size: SnapshotRenderer.settingsSize,
            named: "15-library-settings.png"
        )
    }

    @Test func diagnosticsSettings() async throws {
        let vm = SnapshotSampleContent.loadedViewModel()
        vm.errorMessage = "Failed to open nested archive."

        try await render(
            ZStack {
                PanelyColor.bgPrimary
                DiagnosticsSettingsView(viewModel: vm)
            },
            size: SnapshotRenderer.settingsSize,
            named: "13-diagnostics-settings.png"
        )
    }

    // MARK: - Translation assist

    @Test func translationReading() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        try await render(MockReaderScene().environment(vm).environment(\.locale, Locale(identifier: "en")),
                   size: SnapshotRenderer.heroSize,
                   named: "17-translation-reading.png")
    }

    @Test func translationBeforeAfter() async throws {
        let page = TranslationSnapshotContent.pages[0]
        try await render(
            HStack(spacing: 28) {
                labelled("Original", TranslationSnapshotContent.original(page))
                Image(systemName: "arrow.right")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(PanelyColor.textSecondary)
                labelled("Translation", TranslationSnapshotContent.translatedImage(page))
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelyColor.bgPrimary),
            size: CGSize(width: 1040, height: 760),
            named: "18-translation-before-after.png"
        )
    }

    @Test func translationPanel() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        try await render(
            VStack {
                TranslationPanel()
                    .environment(vm)
                    .background(PanelyColor.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelyColor.bgPrimary)
            .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 380, height: 352),
            named: "19-translation-panel.png"
        )
    }

    @Test func translationBalloonPopover() async throws {
        AppLocalization.shared.apply(.english)
        try await render(
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
            .background(PanelyColor.bgPrimary)
            .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 340, height: 205),
            named: "20-translation-balloon-popover.png"
        )
    }

    @Test func translationExportSheet() async throws {
        let library = try LibraryFixture()
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        vm.translationExports.setDestination(
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Comics/Translated", isDirectory: true)
        )
        let series = library.root.appendingPathComponent("Series A", isDirectory: true)
        let request = TranslationExportRequest(
            books: (1...3).map { series.appendingPathComponent("Volume 0\($0).cbz") },
            title: "Series A",
            isSeries: true,
            suggestedTarget: .english
        )
        try await render(
            TranslationExportSheet(request: request)
                .environment(vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PanelyColor.bgSecondary)
                .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 460, height: 440),
            named: "21-translation-export-sheet.png"
        )
    }

    @Test func jobsWindow() async throws {
        let library = try LibraryFixture()
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        let exports = vm.translationExports
        let output = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Comics/Translated", isDirectory: true)
        let series = library.root.appendingPathComponent("Series A", isDirectory: true)
        let options = TranslationExportOptions(target: .english, format: .cbz, untranslated: .translateFirst)
        func job(_ volume: Int) -> TranslationExportJob {
            let job = TranslationExportJob(bookURL: series.appendingPathComponent("Volume 0\(volume).cbz"), title: "Volume 0\(volume)", options: options)
            exports.add(job)
            return job
        }
        for volume in [1, 2] {
            exports.finish(
                job(volume),
                result: .init(url: output.appendingPathComponent("Volume 0\(volume) [English].cbz"), bytes: Int64(78_000_000 + volume * 3_100_000)),
                pageCount: 184 + volume * 6
            )
        }
        job(3).setStage(.exporting(done: 74, total: 192))
        let oneShot = TranslationExportJob(
            bookURL: library.root.appendingPathComponent("One-shots/Mysterious Tales.cbz"),
            title: "Mysterious Tales",
            options: TranslationExportOptions(target: .korean)
        )
        exports.add(oneShot)
        oneShot.setStage(.failed(
            TranslationController.Notice.needsModelDownload.message(locale: Locale(identifier: "en"))
        ))
        try await render(
            JobsWindowView()
                .environment(vm)
                .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 540, height: 410),
            named: "22-jobs-window.png"
        )
    }

    @Test func experimentalSettings() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        try await render(
            ZStack {
                PanelyColor.bgPrimary
                ExperimentalSettingsView(viewModel: vm)
            }
            .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 620, height: 600),
            named: "23-experimental-settings.png"
        )
    }

    @Test func aiChatSheet() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        try await render(
            AIChatSheet(request: AIChatRequest(scope: .book))
                .environment(vm)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(PanelyColor.bgSecondary)
                .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 520, height: 760),
            named: "24-ai-chat-sheet.png"
        )
    }

    /// Capture the real AppKit selection outline, then the same sample area
    /// as an added balloon. Text is seeded, like the other manual captures,
    /// so regenerating documentation doesn't need a downloaded language pack.
    @Test func addingMissedBalloon() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        vm.setEditingTranslations(true)
        vm.isAddingTranslationBalloon = true
        let sample = TranslationSnapshotContent.pages[0]
        var page = TranslationSnapshotContent.translated(sample)
        let last = page.bubbles.popLast()
        let missed = try #require(last)
        page.pageID = vm.source.pages[0].id
        let size = CGSize(width: 1120, height: 760)
        let hosted = await SnapshotRenderer.host(
            VStack(spacing: 20) {
                ManualBalloonPage(page: page)
                    .frame(width: 400, height: 600)
                TranslationEditBar().environment(vm)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelyColor.bgPrimary)
            .environment(\.locale, Locale(identifier: "en")),
            size: size
        )
        defer { hosted.close() }
        let overlay = try #require(hosted.firstSubview(of: TranslationOverlayView.self))
        let area = CGRect(x: 470, y: 650, width: 230, height: 290)
        let start = CGPoint(x: area.minX / 2, y: area.minY / 2)
        let end = CGPoint(x: area.maxX / 2, y: area.maxY / 2)
        try hosted.drag(in: overlay, from: start, to: end, release: false)
        try hosted.capture(named: "25-translation-drag-selection.png")

        var requested: CGRect?
        overlay.onEdit = { request in
            if case .addBalloon(let rect) = request.change { requested = rect }
        }
        try hosted.sendMouse(.leftMouseUp, in: overlay, at: end)
        #expect(requested == area)

        let added = BubbleEdit(
            recognizedSource: missed.source, rect: area.insetBy(dx: 12, dy: 12),
            retranslations: [TranslationLanguage.english.rawValue: missed.translation ?? ""],
            added: AddedBalloon(glyphSize: missed.glyphSize, isVertical: true, background: .white)
        )
        vm.translationEdits.add(pageID: vm.source.pages[0].id, edit: added)
        vm.isAddingTranslationBalloon = false
        let result = PageEdits(bubbles: [added]).apply(to: page, target: .english)
        let balloon = try #require(result.bubbles.last)
        try await render(
            VStack(spacing: 20) {
                HStack(spacing: 24) {
                    ManualBalloonPage(page: result)
                        .frame(width: 400, height: 600)
                    TranslationBubblePopover(
                        source: balloon.source, translation: balloon.translation,
                        edit: balloon.edit, onEdit: { _ in }
                    )
                    .background(PanelyColor.bgSecondary, in: RoundedRectangle(cornerRadius: 10))
                }
                TranslationEditBar().environment(vm)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(PanelyColor.bgPrimary)
            .environment(\.locale, Locale(identifier: "en")),
            size: size,
            named: "26-translation-added-balloon.png"
        )
    }

    @Test func thumbnailNavigation() async throws {
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
        try await render(
            ThumbnailSidebar(
                pages: pages,
                pageDimensions: Array(repeating: SnapshotSampleContent.pageSize, count: pages.count),
                currentPageIndex: 1, translatedPages: [0, 1], onJump: { _ in }, onClose: {}
            )
            .environment(\.locale, Locale(identifier: "en")),
            size: CGSize(width: 148, height: 650),
            named: "27-thumbnail-navigation.png"
        )
    }

    private func labelled(_ title: LocalizedStringKey, _ image: NSImage) -> some View {
        VStack(spacing: 12) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 620)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(PanelyColor.textPrimary)
        }
    }

    // MARK: - Helpers

    private func render<V: View>(_ view: V, size: CGSize, named name: String) async throws {
        try await SnapshotRenderer.render(view, size: size, named: name)
    }

    private func writeCacheEntry(_ dir: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: byteCount).write(to: dir.appendingPathComponent("pages.bin"))
    }
}

/// The production translation overlay over a locally drawn sample page.
/// The overlay handles the selection mouse events and draws the added badge.
private struct ManualBalloonPage: NSViewRepresentable {
    let page: TranslatedPage

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        let image = NSImageView(frame: view.bounds)
        image.image = TranslationSnapshotContent.original(TranslationSnapshotContent.pages[0])
        image.imageScaling = .scaleAxesIndependently
        image.autoresizingMask = [.width, .height]
        view.addSubview(image)
        let overlay = TranslationOverlayView(frame: view.bounds)
        overlay.autoresizingMask = [.width, .height]
        view.addSubview(overlay)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let overlay = view.subviews.compactMap { $0 as? TranslationOverlayView }.first
        overlay?.update(page: page, showsTranslation: true, isEditing: true, pageOrigin: .zero, scale: 0.5)
    }
}

/// Set by `scripts/generate-snapshots.sh` for its run only (as
/// `TEST_RUNNER_PANELY_GENERATE_SNAPSHOTS`; xcodebuild drops the prefix).
private enum SnapshotGenerationGate {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["PANELY_GENERATE_SNAPSHOTS"] == "1"
    }
}

// MARK: - Mock reader composition

/// SwiftUI-only stand-in for the real reader stage. Mirrors
/// `ReaderScene`'s top-level layout but replaces the AppKit-backed
/// `ViewerContainer` with a plain SwiftUI Image so `ImageRenderer` can
/// produce a clean offscreen capture. Visually faithful enough for the
/// user manual; never shipped in the app binary.
@MainActor
struct MockReaderScene: View {
    @Environment(ReaderViewModel.self) private var viewModel

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 0) {
                if viewModel.sidebarPinned {
                    SidebarHost(requestFocus: {})
                        .frame(width: 240)
                }
                MockViewerSurface()
            }
        }
    }
}

@MainActor
private struct MockViewerSurface: View {
    @Environment(ReaderViewModel.self) private var viewModel

    var body: some View {
        ZStack {
            PanelyColor.bgPrimary
            mockPages
        }
        .overlay(alignment: .top) {
            if viewModel.hasSource {
                ReaderToolbarOverlay(shown: true)
                    .padding(PanelySpacing.md)
                    .environment(ViewerController())
            }
        }
        .overlay(alignment: .bottom) {
            ReaderSliderOverlay(shown: true)
        }
        .overlay(alignment: .bottom) {
            EndOfVolumeCardOverlay(requestFocus: {})
        }
        .overlay(alignment: .top) {
            PreviousVolumeCardOverlay(requestFocus: {})
        }
    }

    @ViewBuilder
    private var mockPages: some View {
        let images = viewModel.currentImages
        if images.isEmpty {
            EmptyView()
        } else if viewModel.layout.isContinuous {
            // Vertical strip: constrain each page so multiple pages stack
            // visibly inside the 800pt viewport (sample pages are 2:3
            // portrait, so 180pt wide = 270pt tall → ~3 pages + a 4th
            // peeking from the bottom). Makes the "scroll" intent obvious
            // in the manual screenshot at a glance.
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(Array(images.enumerated()), id: \.offset) { _, image in
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxWidth: 180)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .disabled(true)
        } else {
            // Paged: 1 (single) or 2 (double) side-by-side, RTL-aware.
            let ordered = viewModel.effectiveDirection.isRTL ? images.reversed() : images
            HStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.offset) { _, image in
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .padding(40)
        }
    }
}
