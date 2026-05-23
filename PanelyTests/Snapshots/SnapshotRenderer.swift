import AppKit
import SwiftUI
@testable import Panely

/// Renders SwiftUI views to PNG files for the user manual. Hosts the view
/// inside an off-screen `NSWindow` (positioned far outside any display so it
/// never flashes) so the AppKit rendering pipeline kicks in fully — SF
/// Symbols resolve, `List(.sidebar)` lays out, NSViewRepresentable subtrees
/// actually draw. `ImageRenderer` was tried first but its offscreen path
/// skips enough machinery that several reader chrome elements rendered as
/// fallback glyphs.
///
/// Output lives in `~/Library/Containers/<bundle>/Data/Library/Caches/panely-snapshots/`
/// because the test bundle inherits the host app's sandbox; the
/// `scripts/generate-snapshots.sh` script copies the PNGs into the repo's
/// `docs/screenshots/` after the run.
@MainActor
enum SnapshotRenderer {
    /// Standard hero-shot canvas. Matches typical macOS app-store screenshot
    /// ratio so the assets drop straight into release notes / website.
    static let heroSize = CGSize(width: 1280, height: 800)
    static let sidebarSize = CGSize(width: 240, height: 720)
    static let toolbarSize = CGSize(width: 920, height: 64)
    static let cardSize = CGSize(width: 520, height: 220)
    static let overlaySize = CGSize(width: 360, height: 140)

    /// Retina scale baked into the PNG so the asset looks crisp when shown
    /// at logical points (e.g., README on a Retina display).
    static let renderScale: CGFloat = 2.0

    /// How long to let the run loop tick so SwiftUI completes its initial
    /// layout pass, `.task` modifiers fire and resolve, and any in-flight
    /// `FileNode.loadTree`-style async loads can finish. 1.5 s is sized to
    /// cover the sidebar's two-phase scan (depth-1 then depth-3) on the
    /// small fixtures we use; the alternative caught LibrarySidebar mid-
    /// load and rendered no Files section at all.
    static let settleSeconds: TimeInterval = 1.5

    /// Render `view` at `size` to `relativePath` under the sandbox cache.
    /// Async so the cooperative thread pool keeps running while we wait
    /// for SwiftUI's `.task` modifiers (LibrarySidebar's `FileNode.loadTree`
    /// in particular) to complete — a synchronous RunLoop wait turned out
    /// to starve those tasks and left the Files section empty.
    @discardableResult
    static func render<V: View>(
        _ view: V,
        size: CGSize,
        named relativePath: String
    ) async throws -> URL {
        // The hosting view forces the SwiftUI tree into the AppKit world.
        // Inject color scheme + frame at this layer so subviews that read
        // them via `@Environment` see the right values.
        let hostingView = NSHostingView(
            rootView: view
                .frame(width: size.width, height: size.height)
                .environment(\.colorScheme, .dark)
        )
        hostingView.frame = NSRect(origin: .zero, size: size)

        // Off-screen window. `borderless` means no titlebar to leak into the
        // capture; `defer: false` builds the backing store immediately so
        // the first display() has something to draw into. The (−20000,
        // −20000) origin keeps the window safely off any conceivable
        // display, even multi-monitor setups.
        let window = NSWindow(
            contentRect: NSRect(x: -20_000, y: -20_000, width: size.width, height: size.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.colorSpace = NSColorSpace.sRGB
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        // Yield the main actor in two phases. Phase 1 lets SwiftUI complete
        // its initial layout pass and fire `.task` modifiers. Phase 2 gives
        // those tasks (e.g., LibrarySidebar's two-stage FileNode scan)
        // enough wall time to finish. `Task.sleep` properly cooperates with
        // the actor scheduler — unlike `RunLoop.run(until:)`, which blocked
        // the loop and starved the SwiftUI render task.
        try? await Task.sleep(for: .milliseconds(100))
        await MainActor.run { hostingView.layoutSubtreeIfNeeded() }
        try? await Task.sleep(for: .seconds(settleSeconds))

        hostingView.layoutSubtreeIfNeeded()
        hostingView.displayIfNeeded()

        // Manual high-DPI bitmap — `bitmapImageRepForCachingDisplay(in:)`
        // would honor the screen scale, but off-screen windows often don't
        // pick one up. Constructing a bitmap at `size × scale` pixels and
        // labelling it as `size` points gives us deterministic Retina
        // output regardless of which display the test machine has.
        let pixelWidth = Int(size.width * renderScale)
        let pixelHeight = Int(size.height * renderScale)
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelWidth,
            pixelsHigh: pixelHeight,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw RenderError.encodingFailed
        }
        bitmap.size = size
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)

        guard let pngData = bitmap.representation(
            using: NSBitmapImageRep.FileType.png,
            properties: [:]
        ) else {
            throw RenderError.encodingFailed
        }

        let destination = try outputDirectory().appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: destination)
        print("📸 \(destination.path)")
        return destination
    }

    /// Output dir for the generated PNGs. The test bundle inherits the
    /// host app's sandbox, which blocks writes to the repo's `docs/`. We
    /// therefore stage PNGs under the sandbox's own Caches dir
    /// (`~/Library/Containers/<bundle>/Data/Library/Caches/panely-snapshots/`)
    /// and let `scripts/generate-snapshots.sh` copy them into the repo
    /// after the test run.
    static func outputDirectory() throws -> URL {
        let caches = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let dir = caches.appendingPathComponent("panely-snapshots", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    enum RenderError: Error {
        case encodingFailed
    }
}
