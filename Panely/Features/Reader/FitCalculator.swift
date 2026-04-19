import CoreGraphics

nonisolated enum FitCalculator {
    /// Magnification that fits `docSize` into `viewport` under the given mode.
    ///
    /// Returns `1.0` (identity) if either dimension is non-positive.
    /// The result is invariant to any current scale of the container — it only
    /// depends on the physical document size and the physical viewport size.
    static func magnification(
        docSize: CGSize,
        viewport: CGSize,
        fitMode: FitMode
    ) -> CGFloat {
        guard docSize.width > 0, docSize.height > 0,
              viewport.width > 0, viewport.height > 0
        else {
            return 1.0
        }

        switch fitMode {
        case .fitScreen:
            return min(viewport.width / docSize.width, viewport.height / docSize.height)
        case .fitWidth:
            return viewport.width / docSize.width
        }
    }
}
