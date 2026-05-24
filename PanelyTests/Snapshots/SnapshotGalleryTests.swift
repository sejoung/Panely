import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Generates `docs/screenshots/*.png` for the user manual.
///
/// The tests stage PNGs in the Debug app sandbox. Regenerate the checked-in
/// manual screenshots via `scripts/generate-snapshots.sh`.
@MainActor
@Suite(
    "Manual Snapshots",
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

    // MARK: - Helpers

    private func render<V: View>(_ view: V, size: CGSize, named name: String) async throws {
        let url = try await SnapshotRenderer.render(view, size: size, named: name)
        print("📸 wrote \(url.path)")
    }

    private func writeCacheEntry(_ dir: URL, byteCount: Int) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(repeating: 0xAB, count: byteCount).write(to: dir.appendingPathComponent("pages.bin"))
    }
}

private enum SnapshotGenerationGate {
    static var isEnabled: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: flagURL.path),
              let modified = attributes[.modificationDate] as? Date
        else { return false }

        return Date().timeIntervalSince(modified) < 30 * 60
    }

    private static var flagURL: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("panely-generate-snapshots.flag")
    }
}

// MARK: - Mock reader composition

/// SwiftUI-only stand-in for the real reader stage. Mirrors
/// `ReaderScene`'s top-level layout but replaces the AppKit-backed
/// `ViewerContainer` with a plain SwiftUI Image so `ImageRenderer` can
/// produce a clean offscreen capture. Visually faithful enough for the
/// user manual; never shipped in the app binary.
@MainActor
private struct MockReaderScene: View {
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
