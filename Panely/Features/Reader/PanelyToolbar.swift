import SwiftUI

struct PanelyToolbar: View {
    let layout: PageLayout
    let direction: ReadingDirection
    let fitMode: FitMode
    let sidebarPinned: Bool
    let onOpen: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    let onToggleLayout: () -> Void
    let onToggleDirection: () -> Void
    let onToggleFitMode: () -> Void
    let onToggleSidebarPin: () -> Void
    var onZoomIn: () -> Void = {}
    var onZoomOut: () -> Void = {}
    var autoFitOnResize: Bool = true
    var onToggleAutoFit: () -> Void = {}

    var showVolumeNav: Bool = false
    var canGoPreviousVolume: Bool = false
    var canGoNextVolume: Bool = false
    var onPreviousVolume: () -> Void = {}
    var onNextVolume: () -> Void = {}

    var body: some View {
        HStack(spacing: PanelySpacing.xs) {
            PanelyIconButton(systemImage: "folder", action: onOpen)
                .help("Open Folder, CBZ, or ZIP… (⌘O)")

            PanelyIconButton(
                systemImage: sidebarPinned ? "pin.fill" : "pin",
                isActive: sidebarPinned,
                action: onToggleSidebarPin
            )
            .help(sidebarPinned ? "Unpin Library (⌃⌘S)" : "Pin Library (⌃⌘S)")

            Divider()
                .frame(height: 18)
                .padding(.horizontal, PanelySpacing.xs)

            PanelyIconButton(
                systemImage: layoutSymbol,
                isActive: layout == .double,
                action: onToggleLayout
            )
            .help(layoutHelp)

            PanelyIconButton(
                systemImage: directionSymbol,
                action: onToggleDirection
            )
            .disabled(layout.isContinuous)
            .help(directionHelp)

            PanelyIconButton(
                systemImage: fitSymbol,
                action: onToggleFitMode
            )
            .help(fitHelp)

            PanelyIconButton(
                systemImage: "minus.magnifyingglass",
                action: onZoomOut
            )
            .help("Zoom Out (⌘−)")

            PanelyIconButton(
                systemImage: "plus.magnifyingglass",
                action: onZoomIn
            )
            .help("Zoom In (⌘+)")

            PanelyIconButton(
                systemImage: autoFitOnResize ? "lock.open" : "lock.fill",
                isActive: !autoFitOnResize,
                action: onToggleAutoFit
            )
            .help(autoFitOnResize
                  ? "Lock view size (don't auto-fit on resize) (⌘L)"
                  : "Unlock view size (auto-fit on resize) (⌘L)")

            Spacer()

            if showVolumeNav {
                PanelyIconButton(systemImage: "chevron.backward.2", action: onPreviousVolume)
                    .disabled(!canGoPreviousVolume)
                    .help("Previous Volume (⌘[)")
            }

            PanelyIconButton(systemImage: "chevron.left", action: onPrev)
                .help("Previous Page (\(previousKeyHint))")

            PanelyIconButton(systemImage: "chevron.right", action: onNext)
                .help("Next Page (\(nextKeyHint) or Space)")

            if showVolumeNav {
                PanelyIconButton(systemImage: "chevron.forward.2", action: onNextVolume)
                    .disabled(!canGoNextVolume)
                    .help("Next Volume (⌘])")
            }
        }
        .padding(.horizontal, PanelySpacing.sm)
        .padding(.vertical, PanelySpacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(PanelyColor.borderSubtle, lineWidth: 1)
                )
        )
    }

    private var layoutSymbol: String {
        switch layout {
        case .single:   return "rectangle.portrait"
        case .double:   return "rectangle.split.2x1"
        case .vertical: return "arrow.up.and.down"
        }
    }

    private var directionSymbol: String {
        direction.isRTL ? "arrow.left" : "arrow.right"
    }

    private var layoutHelp: String {
        switch layout {
        case .single:   return "Switch to Double Page"
        case .double:   return "Switch to Vertical Scroll"
        case .vertical: return "Switch to Single Page"
        }
    }

    private var directionHelp: String {
        if layout.isContinuous {
            return "Reading direction is fixed in vertical mode"
        }
        return direction.isRTL ? "Read Left to Right" : "Read Right to Left"
    }

    private var fitSymbol: String {
        switch fitMode {
        case .fitScreen: return "arrow.up.left.and.arrow.down.right"
        case .fitWidth:  return "arrow.left.and.right"
        case .fitHeight: return "arrow.up.and.down"
        }
    }

    private var fitHelp: String {
        switch fitMode {
        case .fitScreen: return "Fit to Screen — switch to Fit Width (⌘2)"
        case .fitWidth:  return "Fit Width — switch to Fit Height (⌘3)"
        case .fitHeight: return "Fit Height — switch to Fit Screen (⌘1)"
        }
    }

    private var previousKeyHint: String {
        direction.isRTL ? "→" : "←"
    }

    private var nextKeyHint: String {
        direction.isRTL ? "←" : "→"
    }
}

#Preview {
    PanelyToolbar(
        layout: .double,
        direction: .rightToLeft,
        fitMode: .fitScreen,
        sidebarPinned: true,
        onOpen: {},
        onPrev: {},
        onNext: {},
        onToggleLayout: {},
        onToggleDirection: {},
        onToggleFitMode: {},
        onToggleSidebarPin: {},
        showVolumeNav: true,
        canGoPreviousVolume: true,
        canGoNextVolume: false,
        onPreviousVolume: {},
        onNextVolume: {}
    )
    .padding(PanelySpacing.xl)
    .frame(width: 640)
    .background(PanelyColor.bgPrimary)
}
