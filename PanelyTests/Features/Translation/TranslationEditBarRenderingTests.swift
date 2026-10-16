import AppKit
import SwiftUI
import Testing
@testable import Panely

/// Hosts the real balloon edit bar (`TranslationEditBar`) over a translated
/// book and checks it follows edit mode and the reader's edits: it shows
/// only while editing, and offers the hidden-balloon menu and "Revert This
/// Book…" only once something was changed.
///
/// Checked by the controls AppKit has on screen (one per button or menu,
/// see `HostedView.controlFrames`) and whether the bar's capsule is drawn.
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

    /// Every focus-ring view (hidden ones too) and the model state behind the
    /// bar, so a CI failure says which control is missing — the count can
    /// differ between macOS versions.
    private func controlsReport(of hosted: SnapshotRenderer.HostedView, _ vm: ReaderViewModel) -> String {
        let rings = hosted.allSubviews()
            .filter { String(describing: type(of: $0)) == "_FocusRingView" }
            .map { ring in
                let frame = hosted.frameInHost(of: ring, rect: ring.bounds).integral
                return "  \(frame)\(ring.isHiddenOrHasHiddenAncestor ? " hidden" : "")"
            }
        let model = "model:    edited=\(vm.translationEdits.editedCount) hidden=\(vm.translationEdits.hiddenCount)"
            + " hiddenListed=\(vm.translationHiddenBalloons.count) translating=\(vm.translation.isWorking)"
        return model + "\nfocus rings (\(rings.count)):\n" + rings.joined(separator: "\n")
    }

    /// The bar draws a capsule outlined in the accent color over the black
    /// backdrop; without it nothing but black is on screen.
    private func state(of hosted: SnapshotRenderer.HostedView) throws -> BarState {
        let pixels = try hosted.capture()
        let everything = CGRect(origin: .zero, size: Self.size)
        guard pixels.accentPixels(in: everything) > 100 else { return .hidden }
        return .shown(controls: hosted.controlFrames().count)
    }
}
