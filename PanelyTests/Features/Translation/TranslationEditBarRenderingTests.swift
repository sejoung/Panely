import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Hosts the real balloon edit bar (`TranslationEditBar`) over a translated
/// book and checks it follows edit mode and the reader's edits: it shows
/// only while editing, and offers the hidden-balloon menu and "Revert This
/// Book…" only once something was changed.
///
/// Checked by the controls on screen (one per button or menu, see
/// `controlCount`) and whether the bar's capsule is drawn.
@MainActor
struct TranslationEditBarRenderingTests {

    @Test func editModeShowsAndHidesTheBar() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expect(in: hosted, of: vm, .hidden, "reading: no edit bar")

        vm.setEditingTranslations(true)
        // "Translate Page Again" and "Done".
        try await expect(in: hosted, of: vm, .shown(controls: 2), "editing: the bar, nothing changed yet")

        vm.setEditingTranslations(false)
        try await expect(in: hosted, of: vm, .hidden, "back to reading: the bar gone")
    }

    @Test func hidingABalloonOffersItsMenuAndRevert() async throws {
        let vm = try await TranslationSnapshotContent.translatedViewModel()
        vm.setEditingTranslations(true)
        let hosted = await host(vm)
        defer { hosted.close() }
        try await expect(in: hosted, of: vm, .shown(controls: 2), "editing, nothing changed")

        let page = vm.source.pages[0]
        let bubble = try #require(vm.translation.pages[page.id]?.bubbles.first)
        vm.translationEdits.hide(pageID: page.id, bubble: bubble)
        // "1 Hidden" menu, "Translate Page Again", "Revert This Book…", "Done".
        try await expect(in: hosted, of: vm, .shown(controls: 4), "a balloon hidden: its menu and Revert appear")

        vm.translationEdits.showAllHidden()
        try await expect(in: hosted, of: vm, .shown(controls: 2), "shown again: back to two controls")
    }

    // MARK: - Helpers

    private enum BarState: Equatable, CustomStringConvertible {
        case hidden
        case shown(controls: Int)

        var description: String {
            switch self {
            case .hidden: "no bar"
            case .shown(let controls): "bar with \(controls) controls"
            }
        }
    }

    private static let size = CGSize(width: 820, height: 80)

    private func host(_ vm: ReaderViewModel) async -> SnapshotRenderer.HostedView {
        AppLocalization.shared.apply(.english)
        return await SnapshotRenderer.host(
            ZStack {
                Color.black
                TranslationEditBar()
                    .environment(vm)
            }
            .environment(\.locale, Locale(identifier: "en")),
            size: Self.size
        )
    }

    private func expect(
        in hosted: SnapshotRenderer.HostedView,
        of vm: ReaderViewModel,
        _ expected: BarState,
        _ what: String
    ) async throws {
        try await hosted.settle(what, describe: { try "expected: \(expected)\ngot:      \(state(of: hosted))\n\(controlsReport(of: hosted, vm))" }) {
            try state(of: hosted) == expected
        }
    }

    /// The model state behind the bar and what was found on screen, so a
    /// failure says which control is missing.
    private func controlsReport(of hosted: SnapshotRenderer.HostedView, _ vm: ReaderViewModel) throws -> String {
        let rings = hosted.controlFrames()
        let bezels = try rings.first.map { bezelSpans(in: try hosted.capture(), atY: $0.minY + 2) } ?? []
        let model = "model:    edited=\(vm.translationEdits.editedCount) hidden=\(vm.translationEdits.hiddenCount)"
            + " hiddenListed=\(vm.translationHiddenBalloons.count) translating=\(vm.translation.isWorking)"
        return model
            + "\nfocus rings: \(rings.map { "\($0.minX)–\($0.maxX)" })"
            + "\nbezels:      \(bezels.map { "\($0.lowerBound)–\($0.upperBound)" })"
    }

    /// Controls on screen: AppKit's focus-ring views (`controlFrames`), plus
    /// any bordered bezel on the controls' row that has none. macOS 26 gives
    /// the hidden-balloon `Menu` no `_FocusRingView` (27 does), so there its
    /// bezel stands in; a bezel never counts twice for a control with a ring.
    private func controlCount(in hosted: SnapshotRenderer.HostedView, _ pixels: RenderedPixels) -> Int {
        let rings = hosted.controlFrames()
        // All controls share a row; 2 pt down is inside every bezel, above
        // the labels.
        guard let row = rings.first?.minY else { return 0 }
        let ringless = bezelSpans(in: pixels, atY: row + 2).filter { bezel in
            !rings.contains { $0.minX < bezel.upperBound && bezel.lowerBound < $0.maxX }
        }
        return rings.count + ringless.count
    }

    /// Horizontal spans at `y` drawn over the bar's black, at least a small
    /// button wide — bordered bezels; the capsule's outline crosses the row
    /// only a few points wide.
    private func bezelSpans(in pixels: RenderedPixels, atY y: CGFloat) -> [Range<CGFloat>] {
        let black = RenderedPixels.RGB(r: 0, g: 0, b: 0)
        let step = 1 / pixels.scale
        var spans: [Range<CGFloat>] = []
        var start: CGFloat?
        for x in stride(from: 0, through: Self.size.width, by: step) {
            let drawn = x < Self.size.width && pixels.color(at: CGPoint(x: x, y: y)).differs(from: black, by: 15)
            if drawn, start == nil { start = x }
            if !drawn, let begin = start {
                if x - begin >= 20 { spans.append(begin..<x) }
                start = nil
            }
        }
        return spans
    }

    /// The bar draws a capsule outlined in the accent color over the black
    /// backdrop; without it nothing but black is on screen.
    private func state(of hosted: SnapshotRenderer.HostedView) throws -> BarState {
        let pixels = try hosted.capture()
        let everything = CGRect(origin: .zero, size: Self.size)
        guard pixels.accentPixels(in: everything) > 100 else { return .hidden }
        return .shown(controls: controlCount(in: hosted, pixels))
    }
}
