import Testing
import Foundation
@testable import Panely

/// Covers `setLayout(_:)` — direct selection used by the segmented toolbar
/// control and the `⌘⇧1/2/3` menu shortcuts. Behavioural contrast with
/// `toggleLayout()` (which always advances through `.next`).
@MainActor
struct ReaderViewModelSetLayoutTests {

    @Test func setLayoutSwitchesToTarget() {
        let vm = ReaderViewModel()
        vm.layout = .single

        vm.setLayout(.double)
        #expect(vm.layout == .double)
    }

    @Test func setLayoutNoOpsWhenAlreadyAtTarget() {
        // Same-target should not run handleLayoutChange — verifying via the
        // didSet's lack of side effects on `layout`. (We can't easily observe
        // the handler firing here without bringing in a full source, so we
        // check that the value stays stable and a redundant call is silent.)
        let vm = ReaderViewModel()
        vm.layout = .vertical

        vm.setLayout(.vertical)
        #expect(vm.layout == .vertical)
    }

    @Test func setLayoutGoesDirectlyAcrossModesWithoutCycling() {
        // The whole point of split-from-toggle: vertical → double must NOT
        // detour through .single (which `toggleLayout()` would do twice).
        let vm = ReaderViewModel()
        vm.layout = .vertical

        vm.setLayout(.double)
        #expect(vm.layout == .double)
    }

    @Test func toggleLayoutStillCyclesThroughNext() {
        // Backwards-compat: the cycle method survives for tests / any caller
        // that wants to advance one step. setLayout is additive, not a
        // replacement.
        let vm = ReaderViewModel()
        vm.layout = .single
        vm.toggleLayout()
        #expect(vm.layout == .double)
        vm.toggleLayout()
        #expect(vm.layout == .vertical)
        vm.toggleLayout()
        #expect(vm.layout == .single)
    }

    @Test func setLayoutPreservesFitMode() {
        // Same contract as toggleLayout — fitMode is the user's choice and
        // must not be reset by a layout switch. Verifies the segmented
        // picker doesn't accidentally clobber it.
        let vm = ReaderViewModel()
        vm.layout = .single
        vm.fitMode = .fitWidth

        vm.setLayout(.double)
        #expect(vm.fitMode == .fitWidth)
    }

    // MARK: setFitMode

    @Test func setFitModeSwitchesToTarget() {
        let vm = ReaderViewModel()
        vm.fitMode = .fitScreen

        vm.setFitMode(.fitHeight)
        #expect(vm.fitMode == .fitHeight)
    }

    @Test func setFitModeNoOpsWhenAlreadyAtTarget() {
        let vm = ReaderViewModel()
        vm.fitMode = .fitWidth

        vm.setFitMode(.fitWidth)
        #expect(vm.fitMode == .fitWidth)
    }

    @Test func setFitModeGoesDirectlyAcrossModesWithoutCycling() {
        // Same selling point as setLayout: fitScreen → fitHeight skips the
        // fitWidth detour that `toggleFitMode()` would take.
        let vm = ReaderViewModel()
        vm.fitMode = .fitScreen

        vm.setFitMode(.fitHeight)
        #expect(vm.fitMode == .fitHeight)
    }

    @Test func toggleFitModeStillCyclesThroughNext() {
        let vm = ReaderViewModel()
        vm.fitMode = .fitScreen
        vm.toggleFitMode()
        #expect(vm.fitMode == .fitWidth)
        vm.toggleFitMode()
        #expect(vm.fitMode == .fitHeight)
        vm.toggleFitMode()
        #expect(vm.fitMode == .fitScreen)
    }
}
