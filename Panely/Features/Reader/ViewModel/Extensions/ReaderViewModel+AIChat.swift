import Foundation

/// Which pages go to the AI chat.
enum AIChatScope: Hashable {
    /// Page indices, inclusive.
    case pages(ClosedRange<Int>)
    case book
}

/// The AI chat sheet's subject while it's up.
struct AIChatRequest: Identifiable {
    let id = UUID()
    var scope: AIChatScope
}

/// A balloon's translation before a reply changed it, to undo the reply.
struct AIChatUndoEntry {
    let pageID: String
    let bubble: TranslatedBubble
    let target: TranslationLanguage
    /// The reader's own translation before, or `nil` for the machine one.
    let previous: String?
}

/// Improving translations through the reader's own AI chat (`AIChatExchange`):
/// save the book as a text file for the chat, open the chat's reply. Opened
/// from the language menu, a page's right-click menu and the panel's This
/// Book & Series — always on the whole book: a file carries all of it, and a
/// chat reading the whole story keeps speakers and names straight.
extension ReaderViewModel {
    /// There's a translation to improve.
    var canImproveWithAIChat: Bool {
        canTranslateAgain
    }

    func requestAIChat() {
        guard canImproveWithAIChat else { return }
        aiChatRequest = AIChatRequest(scope: .book)
    }

    /// The pages on screen, where choosing pages starts.
    var aiChatCurrentPages: AIChatScope {
        let spread = currentSpread
        guard let first = spread.first, let last = spread.last else { return .pages(currentPageIndex...currentPageIndex) }
        return .pages(first...last)
    }

    /// The balloons `scope` covers, as shown (edits applied), in reading order.
    func aiChatLines(for scope: AIChatScope) -> [AIChatExchange.Line] {
        let indices: [Int]
        switch scope {
        case let .pages(range): indices = Array(range.clamped(to: 0...max(0, source.pages.count - 1)))
        case .book: indices = Array(source.pages.indices)
        }
        let controller = translation
        let pages = indices.compactMap { index -> (index: Int, pageID: String, page: TranslatedPage)? in
            guard source.pages.indices.contains(index) else { return nil }
            let id = source.pages[index].id
            guard let machine = controller.pages[id] else { return nil }
            return (index, id, translationEdits.apply(to: machine, pageID: id, target: controller.target))
        }
        return AIChatExchange.lines(pages: pages)
    }

    /// The text file for `scope` and a name for it; remembers the balloons
    /// it lists so the reply maps back to them.
    func aiChatFile(for scope: AIChatScope) -> (text: String, balloons: Int, fileName: String) {
        let lines = aiChatLines(for: scope)
        aiChatLines = lines
        guard let source = translation.source else { return ("", 0, "") }
        let text = AIChatExchange.fileText(lines, title: self.source.title, from: source, to: translation.target)
        return (text, lines.count, aiChatFileName(for: lines))
    }

    /// "Title p3-12 [ko].txt" for the pages `scope` covers.
    func aiChatFileName(for scope: AIChatScope) -> String {
        aiChatFileName(for: aiChatLines(for: scope))
    }

    private func aiChatFileName(for lines: [AIChatExchange.Line]) -> String {
        let title = source.title
        let pages = Set(lines.map(\.pageIndex))
        var name = title.isEmpty ? "Panely" : title
        if let first = pages.min(), let last = pages.max() {
            name += first == last ? " p\(first + 1)" : " p\(first + 1)-\(last + 1)"
        }
        name += " [\(translation.target.rawValue)].txt"
        return TranslationExportWriter.safeFileName(name)
    }

    /// What to tell the chat along with `fileName`, in the reader's language.
    func aiChatPromptText(fileName: String, balloons: Int) -> String {
        let locale = localization.locale
        return AIChatExchange.prompt(
            fileName: fileName,
            balloons: balloons,
            from: (translation.source ?? .japanese).displayName(in: locale),
            to: translation.target.displayName(in: locale)
        )
    }

    /// Take the chat's reply: each translation it changed becomes the
    /// reader's own for its balloon. Returns what changed; undoable with
    /// `undoAIChatReply()`.
    @discardableResult
    func applyAIChatReply(_ reply: String) -> AIChatExchange.Changes {
        let parsed = AIChatExchange.parse(reply)
        // What was copied — or, after a relaunch, the pages the reply names.
        var lines = aiChatLines
        if lines.isEmpty {
            let pages = parsed.keys.compactMap { Int($0.dropFirst().prefix { $0 != "-" }) }.map { $0 - 1 }
            if let first = pages.min(), let last = pages.max() {
                lines = aiChatLines(for: .pages(first...last))
            }
        }
        let changes = AIChatExchange.changes(from: parsed, lines: lines)
        let target = translation.target
        var undo: [AIChatUndoEntry] = []
        for (line, text) in changes.updates {
            undo.append(AIChatUndoEntry(
                pageID: line.pageID,
                bubble: line.bubble,
                target: target,
                previous: line.bubble.edit?.translationIsReaders == true ? line.translation : nil
            ))
            translationEdits.update(pageID: line.pageID, bubble: line.bubble) { edit in
                edit.translations[target.rawValue] = text
            }
        }
        aiChatUndo = undo.isEmpty ? nil : undo
        AppLog.info(.reader, "AI chat reply applied", metadata: [
            "updated": "\(changes.updates.count)", "unchanged": "\(changes.unchanged)",
            "unknown": "\(changes.unknown)", "missing": "\(changes.missing.count)",
        ])
        return changes
    }

    /// Put back the translations the last reply changed.
    func undoAIChatReply() {
        guard let undo = aiChatUndo else { return }
        for entry in undo {
            translationEdits.update(pageID: entry.pageID, bubble: entry.bubble) { edit in
                edit.translations[entry.target.rawValue] = entry.previous
            }
        }
        aiChatUndo = nil
    }
}
