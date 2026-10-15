import CoreGraphics
import Foundation

/// The reader's own changes to one page's balloons: translations they wrote,
/// originals they corrected (and those corrections translated), and balloons
/// they hid because OCR mistook artwork for text.
///
/// Kept apart from the machine translations (`TranslationStore`, a cache) and
/// laid over them only for display, so clearing the cache, switching modes or
/// translating again never loses them. Per page and scope, for every language
/// — a hidden balloon or a corrected original holds whatever the book is
/// shown in; a written translation belongs to its own language.
nonisolated struct PageEdits: Codable, Sendable, Equatable {
    var bubbles: [BubbleEdit] = []

    var isEmpty: Bool { bubbles.isEmpty }
    var hiddenCount: Int { bubbles.filter(\.isHidden).count }

    func edit(for bubble: TranslatedBubble) -> BubbleEdit? {
        bubbles.first { $0.matches(bubble) }
    }

    /// Change `bubble`'s edit (creating it first); an edit left with nothing
    /// in it is dropped.
    mutating func update(_ bubble: TranslatedBubble, _ change: (inout BubbleEdit) -> Void) {
        update(source: bubble.source, rect: bubble.rect, change)
    }

    /// The same, for a balloon known only by its edit — one that's hidden,
    /// so not on the page to point at.
    mutating func update(source: String, rect: CGRect, _ change: (inout BubbleEdit) -> Void) {
        let index = bubbles.firstIndex { $0.matches(source: source, rect: rect) } ?? {
            bubbles.append(BubbleEdit(recognizedSource: source, rect: rect))
            return bubbles.count - 1
        }()
        change(&bubbles[index])
        if bubbles[index].isEmpty { bubbles.remove(at: index) }
    }

    /// `page` in `target` as the reader left it: hidden balloons gone, their
    /// own translations and corrected originals in place, each edited balloon
    /// marked (`TranslatedBubble.edit`).
    ///
    /// - Parameters:
    ///   - retranslating: originals (as recognised) whose correction is being
    ///     translated into `target` right now — shown as pending.
    ///   - includeHidden: keep hidden balloons, marked (`edit.isHidden`) —
    ///     edit mode outlines them so they can be brought back.
    func apply(
        to page: TranslatedPage,
        target: TranslationLanguage,
        retranslating: Set<String> = [],
        includeHidden: Bool = false
    ) -> TranslatedPage {
        guard !bubbles.isEmpty else { return page }
        var result = page
        result.bubbles = page.bubbles.compactMap { bubble in
            guard let edit = edit(for: bubble) else { return bubble }
            if edit.isHidden {
                guard includeHidden else { return nil }
                var hidden = bubble
                hidden.edit = BubbleEditState(correctedSource: edit.correctedSource, translationIsReaders: false, needsRetranslation: false, isHidden: true)
                return hidden
            }
            var shown = bubble
            let own = edit.translations[target.rawValue]
            let retranslated = edit.retranslations[target.rawValue]
            if let own {
                shown.translation = own
            } else if edit.correctedSource != nil {
                if let retranslated {
                    shown.translation = retranslated
                } else if retranslating.contains(edit.recognizedSource) {
                    shown.translation = nil
                }
            }
            shown.edit = BubbleEditState(
                correctedSource: edit.correctedSource,
                translationIsReaders: own != nil,
                needsRetranslation: edit.correctedSource != nil && own == nil && retranslated == nil
                    && !retranslating.contains(edit.recognizedSource)
            )
            return shown
        }
        return result
    }

    /// What `bubble` reads in `target` once edits apply; `nil` when hidden.
    func translation(of bubble: TranslatedBubble, in target: TranslationLanguage) -> String? {
        guard let edit = edit(for: bubble) else { return bubble.translation }
        guard !edit.isHidden else { return nil }
        if let own = edit.translations[target.rawValue] { return own }
        if edit.correctedSource != nil, let retranslated = edit.retranslations[target.rawValue] { return retranslated }
        return bubble.translation
    }
}

/// One balloon's edits.
nonisolated struct BubbleEdit: Codable, Sendable, Equatable {
    /// Which balloon: its text as OCR recognised it, and where it sits. Balloon
    /// ids are only a count within one analysis; this pair survives analysing
    /// the page again.
    var recognizedSource: String
    var rect: CGRect
    var isHidden = false
    /// The original as the reader corrected it; `nil` = as recognised.
    var correctedSource: String?
    /// Machine translations of `correctedSource`, by target language code.
    var retranslations: [String: String] = [:]
    /// Translations the reader wrote, by target language code.
    var translations: [String: String] = [:]

    var isEmpty: Bool { !isHidden && correctedSource == nil && translations.isEmpty }

    func matches(_ bubble: TranslatedBubble) -> Bool {
        matches(source: bubble.source, rect: bubble.rect)
    }

    func matches(source: String, rect: CGRect) -> Bool {
        source == recognizedSource && rect.intersects(self.rect)
    }
}

/// How a shown balloon differs from the machine translation — set for
/// display by `PageEdits.apply`, read by the balloon popover.
nonisolated struct BubbleEditState: Codable, Sendable, Equatable {
    /// The original as the reader corrected it.
    var correctedSource: String?
    /// The shown translation is the reader's own.
    var translationIsReaders: Bool
    /// The corrected original isn't translated into this language yet, so
    /// the machine translation of the recognised text still shows.
    var needsRetranslation: Bool
    /// Hidden by the reader; only present in edit mode, drawn as an outline.
    var isHidden = false
}
