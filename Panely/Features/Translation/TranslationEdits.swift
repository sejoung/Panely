import CoreGraphics
import Foundation
import Observation

/// What the reader asked for in a balloon's popover.
enum TranslationEditChange: Equatable {
    case setTranslation(String)
    case revertTranslation
    case hide
    case correctSource(String)
    case revertSource
    /// Both of the above: the shown language's own translation and the
    /// corrected original.
    case revertAll
    /// Translate the corrected original into the shown language.
    case retranslate
    /// Bring back a hidden balloon (edit mode shows it as an outline).
    case show
    /// Switch edit mode on or off (a right-click on the page).
    case enterEditMode
    case leaveEditMode
    /// Read and translate this balloon's page again (`bubble` stands in).
    case translatePageAgain
    /// Edit mode, ready to drag out a balloon over missed text.
    case startAddingBalloon
    /// Improve this balloon's page through the reader's AI chat.
    case improveWithAIChat
    /// Add a balloon over this area of the page (in page pixels), dragged
    /// out in edit mode where the analysis found no text.
    case addBalloon(CGRect)
    /// Take away a balloon the reader added.
    case remove
}

/// A balloon edit from the viewer: which page, which balloon (as shown), what.
/// For `.addBalloon` there's no balloon yet; `bubble` only stands in.
struct TranslationEditRequest {
    let pageID: String
    let bubble: TranslatedBubble
    let change: TranslationEditChange
}

/// A hidden balloon as the translation panel lists it.
struct HiddenBalloon: Identifiable {
    let pageIndex: Int
    let pageID: String
    let edit: BubbleEdit

    var id: String { "\(pageID)|\(edit.recognizedSource)|\(edit.rect.minX),\(edit.rect.minY)" }
}

/// The open book's balloon edits (`PageEdits`), loaded for its pages in the
/// scope they're read in and saved as they change. Laid over every
/// language's machine translations for display — see
/// `ReaderViewModel.translationOverlayPages`.
@Observable
@MainActor
final class TranslationEdits {
    /// A corrected original — or an added balloon's text — being translated
    /// into one language.
    struct Retranslation: Hashable {
        let pageID: String
        let recognizedSource: String
        /// The text translated (`BubbleEdit.sourceToTranslate`).
        let correctedSource: String
        let target: TranslationLanguage
    }

    struct RecentlyHidden: Equatable {
        let pageID: String
        let bubble: TranslatedBubble
        let id = UUID()
    }

    /// A balloon just added, offered back for a few seconds — and, when
    /// nothing could be read in it, the hint to type its text.
    struct RecentlyAdded: Equatable {
        let pageID: String
        let edit: BubbleEdit
        let id = UUID()

        var foundNoText: Bool { edit.recognizedSource.isEmpty }
    }

    /// How long the "balloon hidden" banner stays.
    nonisolated static let recentlyHiddenSeconds = 8.0

    let store: TranslationEditStore
    /// By page id, for the open book in `scope`.
    private(set) var pages: [String: PageEdits] = [:]
    private(set) var retranslating: Set<Retranslation> = []
    /// The balloon just hidden, offered back for a few seconds (status banner)
    /// — the moment it's easiest to learn that hiding can be undone.
    private(set) var recentlyHidden: RecentlyHidden?
    private(set) var recentlyAdded: RecentlyAdded?
    @ObservationIgnored private(set) var scope: TranslationScope = .page
    @ObservationIgnored private var loadedPageIDs: [String] = []
    @ObservationIgnored private var generation = 0
    /// Saves run one after another, so quick edits land in order.
    @ObservationIgnored private var lastSave: Task<Void, Never>?

    init(store: TranslationEditStore) {
        self.store = store
    }

    /// Hidden balloons in the open book.
    var hiddenCount: Int {
        pages.values.reduce(0) { $0 + $1.hiddenCount }
    }

    /// Balloons the reader added in the open book.
    var addedCount: Int {
        pages.values.reduce(0) { $0 + $1.bubbles.filter { $0.added != nil }.count }
    }

    /// Balloons with any edit in the open book, hidden and added ones included.
    var editedCount: Int {
        pages.values.reduce(0) { $0 + $1.bubbles.count }
    }

    /// The open book's hidden balloons, by page id.
    var hiddenBalloons: [(pageID: String, edit: BubbleEdit)] {
        pages.flatMap { pageID, edits in
            edits.bubbles.filter(\.isHidden).map { (pageID, $0) }
        }
    }

    /// Load the edits for a book's pages read in `scope`. A no-op when that's
    /// what's loaded already (settings changes reload translations too).
    func load(pageIDs: [String], scope: TranslationScope) async {
        guard pageIDs != loadedPageIDs || scope != self.scope else { return }
        generation &+= 1
        let generation = generation
        loadedPageIDs = pageIDs
        self.scope = scope
        pages = [:]
        retranslating = []
        recentlyHidden = nil
        recentlyAdded = nil
        guard !pageIDs.isEmpty else { return }
        let store = store
        let loaded = await Task.detached(priority: .utility) {
            var found: [String: PageEdits] = [:]
            for id in pageIDs {
                if let edits = store.load(key: TranslationEditStore.key(pageID: id, scope: scope)) {
                    found[id] = edits
                }
            }
            return found
        }.value
        guard self.generation == generation else { return }
        pages = loaded
    }

    func edits(forPage pageID: String) -> PageEdits? {
        pages[pageID]
    }

    /// `page` in `target` with the reader's edits; `includeHidden` for edit mode.
    func apply(to page: TranslatedPage, pageID: String, target: TranslationLanguage, includeHidden: Bool = false) -> TranslatedPage {
        guard let edits = pages[pageID] else { return page }
        let inFlight = Set(retranslating.filter { $0.pageID == pageID && $0.target == target }.map(\.recognizedSource))
        return edits.apply(to: page, target: target, retranslating: inFlight, includeHidden: includeHidden)
    }

    func update(pageID: String, bubble: TranslatedBubble, _ change: (inout BubbleEdit) -> Void) {
        var edits = pages[pageID] ?? PageEdits()
        edits.update(bubble, change)
        pages[pageID] = edits.isEmpty ? nil : edits
        save(edits, pageID: pageID)
    }

    /// Add a balloon the reader marked out.
    func add(pageID: String, edit: BubbleEdit) {
        var edits = pages[pageID] ?? PageEdits()
        edits.add(edit)
        pages[pageID] = edits
        save(edits, pageID: pageID)
        let added = RecentlyAdded(pageID: pageID, edit: edit)
        recentlyAdded = added
        // Longer when there's something to do: type the text.
        let seconds = added.foundNoText ? Self.recentlyHiddenSeconds * 2 : Self.recentlyHiddenSeconds
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            if self?.recentlyAdded == added { self?.recentlyAdded = nil }
        }
    }

    /// Take away a balloon the reader added.
    func remove(pageID: String, source: String, rect: CGRect) {
        if recentlyAdded?.pageID == pageID, recentlyAdded?.edit.rect == rect { recentlyAdded = nil }
        guard var edits = pages[pageID] else { return }
        edits.bubbles.removeAll { $0.added != nil && $0.recognizedSource == source && $0.rect == rect }
        pages[pageID] = edits.isEmpty ? nil : edits
        save(edits, pageID: pageID)
    }

    /// Take back the balloon just added.
    func undoAdd() {
        guard let added = recentlyAdded else { return }
        remove(pageID: added.pageID, source: added.edit.recognizedSource, rect: added.edit.rect)
    }

    func dismissRecentlyAdded() {
        recentlyAdded = nil
    }

    func hide(pageID: String, bubble: TranslatedBubble) {
        update(pageID: pageID, bubble: bubble) { $0.isHidden = true }
        let hidden = RecentlyHidden(pageID: pageID, bubble: bubble)
        recentlyHidden = hidden
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.recentlyHiddenSeconds))
            if self?.recentlyHidden == hidden { self?.recentlyHidden = nil }
        }
    }

    /// Bring back the balloon just hidden.
    func undoHide() {
        guard let hidden = recentlyHidden else { return }
        recentlyHidden = nil
        update(pageID: hidden.pageID, bubble: hidden.bubble) { $0.isHidden = false }
    }

    func dismissRecentlyHidden() {
        recentlyHidden = nil
    }

    /// Show one hidden balloon again.
    func showHidden(pageID: String, edit: BubbleEdit) {
        if recentlyHidden?.pageID == pageID, recentlyHidden.map({ edit.matches($0.bubble) }) == true {
            recentlyHidden = nil
        }
        var edits = pages[pageID] ?? PageEdits()
        edits.update(source: edit.recognizedSource, rect: edit.rect) { $0.isHidden = false }
        pages[pageID] = edits.isEmpty ? nil : edits
        save(edits, pageID: pageID)
    }

    /// Drop every edit in the open book — the rest of the library keeps its own.
    func revertAllInBook() {
        recentlyHidden = nil
        recentlyAdded = nil
        retranslating = []
        for pageID in Array(pages.keys) {
            pages[pageID] = nil
            save(PageEdits(), pageID: pageID)
        }
    }

    /// Show every balloon hidden in the open book again.
    func showAllHidden() {
        recentlyHidden = nil
        for (pageID, var edits) in pages where edits.hiddenCount > 0 {
            for index in edits.bubbles.indices { edits.bubbles[index].isHidden = false }
            edits.bubbles.removeAll(where: \.isEmpty)
            pages[pageID] = edits.isEmpty ? nil : edits
            save(edits, pageID: pageID)
        }
    }

    func beginRetranslation(_ retranslation: Retranslation) {
        retranslating.insert(retranslation)
    }

    /// `text` is `nil` when translating failed; the balloon then offers to
    /// try again.
    func finishRetranslation(_ retranslation: Retranslation, bubble: TranslatedBubble, text: String?) {
        guard retranslating.remove(retranslation) != nil else { return }
        guard let text else { return }
        update(pageID: retranslation.pageID, bubble: bubble) { edit in
            // The correction may have been reverted or changed meanwhile.
            guard edit.sourceToTranslate == retranslation.correctedSource else { return }
            edit.retranslations[retranslation.target.rawValue] = text
        }
    }

    /// Delete every edit (Settings), the open book's included.
    func removeAll() async {
        generation &+= 1
        pages = [:]
        retranslating = []
        recentlyHidden = nil
        let store = store
        let previous = lastSave
        await Task.detached(priority: .utility) {
            await previous?.value
            store.clear()
        }.value
    }

    private func save(_ edits: PageEdits, pageID: String) {
        let store = store
        let key = TranslationEditStore.key(pageID: pageID, scope: scope)
        let previous = lastSave
        lastSave = Task.detached(priority: .utility) {
            await previous?.value
            do {
                try store.save(edits, key: key)
            } catch {
                AppLog.error(.reader, "Saving translation edits failed", metadata: ["error": "\(error)"])
            }
        }
    }
}
