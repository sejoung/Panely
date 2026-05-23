import SwiftUI

/// End-of-volume card — auto-appears at the last page when a next sibling
/// is available. Asymmetric vs `PreviousVolumeCardOverlay`, which only shows
/// after the user explicitly signals intent via `goBackward()` at page 0.
struct EndOfVolumeCardOverlay: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let requestFocus: () -> Void

    var body: some View {
        if viewModel.showsEndOfVolumeCard, let name = viewModel.nextVolumeDisplayName {
            EndOfVolumeCard(
                nextVolumeName: name,
                onNext: {
                    viewModel.nextVolume()
                    requestFocus()
                },
                onRestart: {
                    viewModel.restartCurrentVolume()
                    requestFocus()
                }
            )
            .animation(PanelyMotion.uiReveal, value: viewModel.showsEndOfVolumeCard)
        }
    }
}

/// Previous-volume card — surfaces only after the user has pressed back at
/// page 0. Without that gate, every fresh open of a non-first volume would
/// prompt about its predecessor before the reader has read a single page.
struct PreviousVolumeCardOverlay: View {
    @Environment(ReaderViewModel.self) private var viewModel
    let requestFocus: () -> Void

    var body: some View {
        if viewModel.showsPreviousVolumeCard, let name = viewModel.previousVolumeDisplayName {
            PreviousVolumeCard(
                previousVolumeName: name,
                onPrevious: {
                    viewModel.previousVolume()
                    requestFocus()
                }
            )
            .animation(PanelyMotion.uiReveal, value: viewModel.showsPreviousVolumeCard)
        }
    }
}
