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
/// Output lives in the Debug host app's sandbox caches, under
/// `panely-snapshots/`;
/// `scripts/generate-snapshots.sh` copies the PNGs into the repo's
/// `docs/screenshots/` after the run. Keeping Debug on a separate bundle ID
/// prevents snapshot tests from writing into the released app's container.
@MainActor
enum SnapshotRenderer {
    /// Standard hero-shot canvas. Matches typical macOS app-store screenshot
    /// ratio so the assets drop straight into release notes / website.
    static let heroSize = CGSize(width: 1280, height: 800)
    static let sidebarSize = CGSize(width: 240, height: 720)
    static let toolbarSize = CGSize(width: 920, height: 64)
    static let cardSize = CGSize(width: 520, height: 220)
    static let overlaySize = CGSize(width: 360, height: 140)
    static let settingsSize = CGSize(width: 620, height: 420)

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
        let pngData = try await renderPNG(view, size: size)
        let destination = try outputDirectory().appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try pngData.write(to: destination)
        print("📸 \(destination.path)")
        return destination
    }

    /// Render `view` at `size` and return the PNG bytes, for callers that
    /// compare instead of writing (`VisualRegressionTests`).
    static func renderPNG<V: View>(_ view: V, size: CGSize) async throws -> Data {
        let hosted = await host(view, size: size)
        defer { hosted.close() }
        try? await Task.sleep(for: .seconds(settleSeconds))
        return try hosted.pngData()
    }

    /// Host `view` in an off-screen window and give SwiftUI its first layout
    /// pass. Callers wait for whatever async state they need (a fixed settle
    /// for captures, a polled condition for `LibrarySidebarRenderingTests`)
    /// and must `close()` the result.
    static func host<V: View>(_ view: V, size: CGSize) async -> HostedView {
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

        // Yield the main actor so SwiftUI completes its initial layout pass
        // and fires `.task` modifiers. `Task.sleep` properly cooperates with
        // the actor scheduler — unlike `RunLoop.run(until:)`, which blocked
        // the loop and starved the SwiftUI render task.
        try? await Task.sleep(for: .milliseconds(100))
        hostingView.layoutSubtreeIfNeeded()
        return HostedView(window: window, hostingView: hostingView, size: size)
    }

    /// A view on screen (off-screen, really) in its own window.
    @MainActor
    final class HostedView {
        let window: NSWindow
        let hostingView: NSView
        let size: CGSize

        init(window: NSWindow, hostingView: NSView, size: CGSize) {
            self.window = window
            self.hostingView = hostingView
            self.size = size
        }

        func close() {
            window.close()
        }

        /// First view of type `T` in the hosted hierarchy, depth-first —
        /// e.g. the `NSOutlineView` that backs a SwiftUI `List`.
        func firstSubview<T: NSView>(of type: T.Type) -> T? {
            func find(_ view: NSView) -> T? {
                if let match = view as? T { return match }
                for subview in view.subviews {
                    if let match = find(subview) { return match }
                }
                return nil
            }
            return find(hostingView)
        }

        func pngData() throws -> Data {
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
            return pngData
        }
    }

    /// Output dir for the generated PNGs. The test bundle inherits the
    /// Debug host app's sandbox, which blocks writes to the repo's `docs/`.
    /// We therefore stage PNGs under that sandbox's own Caches dir and let
    /// `scripts/generate-snapshots.sh` copy them into the repo after the run.
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
