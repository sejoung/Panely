import Foundation

/// Volume / sibling navigation: counter labels, prev/next sibling stepping,
/// and the end- and start-of-volume card decisions. Reads `siblings` and
/// `currentSourceURL` from the viewmodel; drives `load(url:knownSiblings:intent:)`
/// for the actual book switch.
extension ReaderViewModel {

    // MARK: - Sibling lookup

    var currentSiblingIndex: Int? {
        guard let current = currentSourceURL else { return nil }
        let target = current.standardizedFileURL
        return siblings.firstIndex { $0.standardizedFileURL == target }
    }

    var hasMultipleVolumes: Bool { siblings.count > 1 }

    var canGoPreviousVolume: Bool {
        guard let idx = currentSiblingIndex else { return false }
        return idx > 0
    }

    var canGoNextVolume: Bool {
        guard let idx = currentSiblingIndex else { return false }
        return idx + 1 < siblings.count
    }

    // MARK: - Counter labels

    var volumeCounterLabel: String? {
        guard hasMultipleVolumes, let idx = currentSiblingIndex else { return nil }
        return "Vol \(idx + 1) / \(siblings.count)"
    }

    var combinedCounterLabel: String {
        guard let vol = volumeCounterLabel else { return pageCounterLabel }
        return "\(vol) · \(pageCounterLabel)"
    }

    /// Volumes to surface as a dedicated sidebar section. Only populated for
    /// zip-in-zip (when the volumes live inside `tempDir` and are not visible
    /// in the Files tree). For folder/cbz series the volumes already appear
    /// in the tree under the parent folder, so a separate section would just
    /// duplicate what's already on screen.
    var sidebarVolumes: [URL] {
        guard hasMultipleVolumes, tempDir.isActive else { return [] }
        return siblings
    }

    // MARK: - Stepping between volumes

    func nextVolume() {
        guard canGoNextVolume, let idx = currentSiblingIndex else { return }
        let target = siblings[idx + 1]
        let preservedSiblings = siblings
        Task {
            await load(
                url: target,
                knownSiblings: preservedSiblings,
                intent: .nextVolumeFromEnd
            )
        }
    }

    func previousVolume() {
        guard canGoPreviousVolume, let idx = currentSiblingIndex else { return }
        let target = siblings[idx - 1]
        let preservedSiblings = siblings
        Task { await load(url: target, knownSiblings: preservedSiblings, intent: .previousVolume) }
    }

    // MARK: - End-of-volume card

    /// True when the user is on the final page/spread — i.e., when `next()`
    /// would no-op. Mirrors `next()`'s guard exactly so the card appears
    /// precisely when forward navigation runs out, in both paged and vertical
    /// layouts.
    var isAtLastPage: Bool {
        let count = source.pageCount
        guard count > 0 else { return false }
        return currentPageIndex + navigationStep >= count
    }

    /// Drives the end-of-volume card. Visible only when there's a next sibling
    /// to advance to — last volume in a series shows nothing rather than a
    /// "completion" toast (kept simple for v1).
    var showsEndOfVolumeCard: Bool {
        isAtLastPage && canGoNextVolume
    }

    /// Filename (no extension) of the next sibling. Used as the card's
    /// preview label so users see *which* volume they'd advance to.
    var nextVolumeDisplayName: String? {
        guard canGoNextVolume, let idx = currentSiblingIndex else { return nil }
        return siblings[idx + 1].deletingPathExtension().lastPathComponent
    }

    /// Restart the current volume from page 1. Used by the card's secondary
    /// action so users can re-read without picking from the slider.
    func restartCurrentVolume() {
        jump(toPageNumber: 1)
    }

    // MARK: - Previous-volume card

    /// Drives the previous-volume card. Asymmetric vs `showsEndOfVolumeCard`
    /// on purpose: that card auto-appears whenever you're at the last page,
    /// but this one only surfaces after the user has signaled intent (via
    /// `goBackward()`). Otherwise opening Vol N (which lands on page 0 on
    /// first read) would noisily prompt about Vol N-1 every time.
    var showsPreviousVolumeCard: Bool {
        wantsPreviousVolumePrompt && canGoPreviousVolume
    }

    /// Filename (no extension) of the previous sibling.
    var previousVolumeDisplayName: String? {
        guard canGoPreviousVolume, let idx = currentSiblingIndex else { return nil }
        return siblings[idx - 1].deletingPathExtension().lastPathComponent
    }
}
