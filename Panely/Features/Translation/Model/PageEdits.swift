import CoreGraphics
import Foundation

/// The reader's own changes to one page's balloons: translations they wrote,
/// originals they corrected (and those corrections translated), balloons
/// they hid because OCR mistook artwork for text, and balloons they added
/// where text was missed (`BubbleEdit.added`).
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

    /// The edit of one of the page's own balloons (never an added one that
    /// happens to sit on it).
    func edit(for bubble: TranslatedBubble) -> BubbleEdit? {
        bubbles.first { $0.added == nil && $0.matches(bubble) }
    }

    /// Add a balloon where the analysis found none.
    mutating func add(_ edit: BubbleEdit) {
        bubbles.append(edit)
    }

    /// Id of the `index`-th edit when shown as an added balloon — clear of
    /// the page's own ids, which count up from 0.
    static func addedBubbleID(_ index: Int) -> Int {
        1_000_000 + index
    }

    /// Change `bubble`'s edit (creating it first); an edit left with nothing
    /// in it is dropped.
    mutating func update(_ bubble: TranslatedBubble, _ change: (inout BubbleEdit) -> Void) {
        update(source: bubble.source, rect: bubble.rect, change)
    }

    /// The same, for a balloon known only by its edit — one that's hidden,
    /// so not on the page to point at.
    mutating func update(source: String, rect: CGRect, _ change: (inout BubbleEdit) -> Void) {
        // An added balloon by its exact place; a page balloon by text and
        // place, never landing on an added one.
        let index = bubbles.firstIndex { $0.added != nil && $0.recognizedSource == source && $0.rect == rect }
            ?? bubbles.firstIndex { $0.added == nil && $0.matches(source: source, rect: rect) } ?? {
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
        result.bubbles += addedBubbles(target: target, retranslating: retranslating, isEditing: includeHidden)
        return result
    }

    /// The balloons the reader added, as shown in `target`: their own
    /// translation, else the machine one. With nothing to show yet, edit mode
    /// outlines them (`translation == nil`) and reading leaves them out.
    private func addedBubbles(target: TranslationLanguage, retranslating: Set<String>, isEditing: Bool) -> [TranslatedBubble] {
        bubbles.enumerated().compactMap { index, edit in
            guard let added = edit.added else { return nil }
            let own = edit.translations[target.rawValue]
            let machine = edit.retranslations[target.rawValue]
            let pending = retranslating.contains(edit.recognizedSource)
            let translation = own ?? machine
            guard translation != nil || isEditing || pending else { return nil }
            return TranslatedBubble(
                id: Self.addedBubbleID(index),
                rect: edit.rect,
                glyphSize: added.glyphSize,
                isVertical: added.isVertical,
                source: edit.recognizedSource,
                translation: translation,
                background: added.background,
                edit: BubbleEditState(
                    correctedSource: edit.correctedSource,
                    translationIsReaders: own != nil,
                    needsRetranslation: translation == nil && !pending && edit.sourceToTranslate != nil,
                    isAdded: true
                )
            )
        }
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
    /// Set for a balloon the reader added: there's no machine translation
    /// under it — `retranslations` hold its translations of
    /// `sourceToTranslate`.
    var added: AddedBalloon? = nil

    var isEmpty: Bool { added == nil && !isHidden && correctedSource == nil && translations.isEmpty }

    /// The text machine-translated for this balloon: a correction, or an
    /// added balloon's text as read. `nil` for a page balloon that wasn't
    /// corrected (its machine translation is the analysis's), or an added one
    /// nothing could be read in yet.
    var sourceToTranslate: String? {
        if let correctedSource { return correctedSource }
        guard added != nil, !recognizedSource.isEmpty else { return nil }
        return recognizedSource
    }

    func matches(_ bubble: TranslatedBubble) -> Bool {
        matches(source: bubble.source, rect: bubble.rect)
    }

    func matches(source: String, rect: CGRect) -> Bool {
        source == recognizedSource && rect.intersects(self.rect)
    }
}

/// What an added balloon looks like — the parts the analysis would have
/// found for a balloon of its own.
nonisolated struct AddedBalloon: Codable, Sendable, Equatable {
    var glyphSize: Double
    var isVertical: Bool
    var background: BubbleBackground
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
    /// Added by the reader where the analysis found nothing.
    var isAdded = false
}
