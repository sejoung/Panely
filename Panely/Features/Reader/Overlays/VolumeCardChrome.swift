import SwiftUI

/// Shared chrome for `EndOfVolumeCard` / `PreviousVolumeCard`. Background
/// material, dark reservoir tint, subtle border, drop shadow — pulled out
/// of the two cards so a style tweak (corner radius, shadow, tint) only
/// has to be made in one place.
struct VolumeCardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(PanelySpacing.lg)
            .frame(maxWidth: 360, alignment: .leading)
            .background(
                // Regular material gives more opacity than ultra-thin, and
                // the dark reservoir tint on top guarantees a consistent
                // dark backdrop regardless of the comic page color
                // underneath — textSecondary on white pages was washing
                // out otherwise.
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(PanelyColor.bgSecondary.opacity(0.55))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(PanelyColor.borderSubtle, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }
}

extension View {
    func volumeCardChrome() -> some View { modifier(VolumeCardChrome()) }
}
