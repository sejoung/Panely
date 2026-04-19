import SwiftUI

struct PanelyToolbar: View {
    let layout: PageLayout
    let direction: ReadingDirection
    let onOpen: () -> Void
    let onPrev: () -> Void
    let onNext: () -> Void
    let onToggleLayout: () -> Void
    let onToggleDirection: () -> Void

    var showVolumeNav: Bool = false
    var canGoPreviousVolume: Bool = false
    var canGoNextVolume: Bool = false
    var onPreviousVolume: () -> Void = {}
    var onNextVolume: () -> Void = {}

    var onToggleSidebar: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: PanelySpacing.xs) {
            PanelyIconButton(systemImage: "folder", action: onOpen)
                .help("Open Folder or CBZ… (⌘O)")

            if let onToggleSidebar {
                PanelyIconButton(systemImage: "sidebar.left", action: onToggleSidebar)
                    .help("Toggle Sidebar")
            }

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
            .help(directionHelp)

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
        case .double:   return "Switch to Single Page"
        case .vertical: return "Switch to Single Page"
        }
    }

    private var directionHelp: String {
        direction.isRTL ? "Read Left to Right" : "Read Right to Left"
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
        onOpen: {},
        onPrev: {},
        onNext: {},
        onToggleLayout: {},
        onToggleDirection: {},
        showVolumeNav: true,
        canGoPreviousVolume: true,
        canGoNextVolume: false,
        onPreviousVolume: {},
        onNextVolume: {},
        onToggleSidebar: {}
    )
    .padding(PanelySpacing.xl)
    .frame(width: 640)
    .background(PanelyColor.bgPrimary)
}
