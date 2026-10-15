import CoreGraphics
import Foundation

/// The translation assist's result for one page: where each balloon's text
/// sits and what it says, in the page's own pixel space. Cached on disk by
/// `TranslationStore` and drawn over the original by `TranslationOverlayView`
/// — the page image itself is never rewritten.
///
/// Built up progressively while a job runs: balloons appear as soon as OCR
/// finds them (`translation == nil`), translations fill in one by one, and the
/// page is `isComplete` once every unit of work covering it has finished.
/// Only complete pages are cached.
nonisolated struct TranslatedPage: Codable, Sendable, Equatable {
    /// Bump when the analysis changes enough that old cache entries should
    /// be ignored (it's part of the store key).
    static let formatVersion = 2

    var imageWidth: Double
    var imageHeight: Double
    var bubbles: [TranslatedBubble]
    var isComplete: Bool = true
    /// The `ComicPage.id` this page belongs to, filled in for display so a
    /// balloon edit can name its page — never cached.
    var pageID: String? = nil
    /// The translations' speech levels were matched to the original's
    /// (`SpeechLevel`). Pages cached before that existed are matched when
    /// next loaded.
    var speechLevelChecked: Bool? = nil

    var pendingCount: Int { bubbles.filter { $0.translation == nil }.count }
}

nonisolated struct TranslatedBubble: Codable, Sendable, Equatable, Identifiable {
    var id: Int
    /// Bounds of the source text in page pixels, top-left origin. In strip
    /// scope a balloon crossing into the next slice extends past the page.
    var rect: CGRect
    /// Approximate glyph size of the source text in page pixels — the column
    /// width for vertical text, the line height for horizontal text. Sizes the
    /// padding and caps the translated font so it never outgrows the original.
    var glyphSize: Double
    var isVertical: Bool
    var source: String
    /// `nil` while the translation is still on its way.
    var translation: String?
    var background: BubbleBackground
    /// The same balloon in the book's other translated languages, filled in
    /// for display (balloon popover) — never cached.
    var alternates: [TranslationLanguage: String]? = nil
    /// How the reader changed this balloon, filled in for display
    /// (`PageEdits.apply`) — never cached.
    var edit: BubbleEditState? = nil
}

/// Tone behind a balloon's text, sampled from the page so the translation
/// patch blends in (a white balloon, a tinted caption box, dark artwork).
nonisolated struct BubbleBackground: Codable, Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    /// True when the area is one flat tone — a balloon or caption box, where
    /// a solid patch is invisible. False over artwork, where the overlay
    /// feathers the patch instead of pasting a hard box on the drawing.
    var isUniform: Bool

    var luminance: Double { 0.299 * red + 0.587 * green + 0.114 * blue }
    var isDark: Bool { luminance < 0.5 }

    static let white = BubbleBackground(red: 1, green: 1, blue: 1, isUniform: true)
}
