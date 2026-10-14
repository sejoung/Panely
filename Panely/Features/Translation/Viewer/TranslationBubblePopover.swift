import SwiftUI

/// What a balloon click shows: the translation, the original, and a reminder
/// that it's machine translated. Both texts are selectable, so a word can be
/// copied or looked up (Look Up in the context menu) — the original matters as
/// much as the translation for following along.
///
/// Hosted in an `NSPopover` outside the main SwiftUI tree, so it doesn't
/// inherit the app's `\.locale`; its one UI string is resolved through
/// `Bundle.localized` instead.
struct TranslationBubblePopover: View {
    let source: String
    /// `nil` while the translation is still on its way.
    let translation: String?
    /// The same balloon in the book's other translated languages.
    var alternates: [TranslationLanguage: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: PanelySpacing.sm) {
            if let translation {
                Text(verbatim: translation)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(PanelyColor.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: PanelySpacing.xs) {
                    ProgressView()
                        .controlSize(.small)
                    Text(verbatim: String(localized: "Translating…", bundle: .localized))
                        .foregroundStyle(PanelyColor.textSecondary)
                }
            }

            if !alternates.isEmpty {
                let locale = AppLocalization.shared.locale
                ForEach(alternates.keys.sorted { $0.rawValue < $1.rawValue }, id: \.self) { language in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(verbatim: language.displayName(in: locale))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(PanelyColor.textSecondary)
                        Text(verbatim: alternates[language] ?? "")
                            .font(.system(size: 13))
                            .foregroundStyle(PanelyColor.textPrimary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            Text(verbatim: source)
                .font(.system(size: 14))
                .foregroundStyle(PanelyColor.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Label {
                Text(verbatim: String(localized: "Machine translation", bundle: .localized))
            } icon: {
                Image(systemName: "character.bubble")
            }
            .font(.caption)
            .foregroundStyle(PanelyColor.textSecondary.opacity(0.8))
        }
        .padding(PanelySpacing.md)
        .frame(width: 300, alignment: .leading)
    }
}

#Preview {
    TranslationBubblePopover(
        source: "あの方のお導きに誤りなどあるはずがございません",
        translation: "그 분의 인도에 오류 등이 있을 리가 없습니다."
    )
    .preferredColorScheme(.dark)
}
