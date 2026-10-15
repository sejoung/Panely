import CoreGraphics
import Foundation

/// A round trip through an AI chat the reader already uses (ChatGPT, Claude,
/// Gemini…): Panely copies the balloons — original and current translation,
/// in reading order — with instructions; the reader pastes them into the
/// chat and pastes the reply back; the reply's translations become the
/// reader's own (`BubbleEdit.translations`), revertible like any edit.
///
/// A large model reading a whole page or book fixes what one balloon at a
/// time can't — who's speaking, how they speak, names kept the same — and
/// nothing leaves the Mac unless the reader pastes it somewhere. Each balloon
/// carries an id, "[p12-3]" (page 12, third balloon), so the reply maps back
/// however the chat formats it.
nonisolated enum AIChatExchange {
    /// One balloon as copied.
    struct Line: Equatable, Sendable {
        let id: String
        let pageIndex: Int
        let pageID: String
        /// The balloon as shown (edits applied) — what an edit is made on.
        let bubble: TranslatedBubble
        /// The original as shown: corrected, else as read.
        let source: String
        let translation: String
    }

    /// The lines for pages, each page's balloons in reading order, numbered
    /// from 1 per page. Balloons without a translation to improve are left out.
    static func lines(pages: [(index: Int, pageID: String, page: TranslatedPage)]) -> [Line] {
        pages.sorted { $0.index < $1.index }.flatMap { index, pageID, page in
            page.bubbles
                .filter { $0.edit?.isHidden != true && !($0.translation ?? "").isEmpty }
                .sorted { $0.id < $1.id }
                .enumerated()
                .map { number, bubble in
                    Line(
                        id: "p\(index + 1)-\(number + 1)",
                        pageIndex: index,
                        pageID: pageID,
                        bubble: bubble,
                        source: bubble.edit?.correctedSource ?? bubble.source,
                        translation: bubble.translation ?? ""
                    )
                }
        }
    }

    /// The balloons as a text file to attach to the chat — attached, a long
    /// book isn't cut short the way pasted text can be.
    static func fileText(_ lines: [Line], title: String, from source: TranslationLanguage, to target: TranslationLanguage) -> String {
        let english = Locale(identifier: "en")
        let pages = Set(lines.map(\.pageIndex))
        var text = "# Panely — \(title.isEmpty ? "comic" : "\"\(title)\"") — \(source.displayName(in: english)) → \(target.displayName(in: english))"
        text += " — \(lines.count) balloons"
        if let first = pages.min(), let last = pages.max() {
            text += first == last ? ", page \(first + 1)" : ", pages \(first + 1)–\(last + 1)"
        }
        text += "\n# Each line: [id] original → current translation\n"
        for line in lines {
            text += "[\(line.id)] \(flattened(line.source)) → \(flattened(line.translation))\n"
        }
        return text
    }

    /// What to tell the chat along with the file, in the reader's language
    /// (shown to copy, and to change if they like). It asks for every
    /// balloon back, so a balloon the chat dropped shows as missing.
    static func prompt(fileName: String, balloons: Int, from source: String, to target: String) -> String {
        String(localized: """
        The attached file “\(fileName)” has \(balloons) speech balloons from a comic, in reading order. Each line is: [id] original (\(source)) → current machine translation (\(target)). The machine translated one balloon at a time, without context.

        Improve the translations using the whole text:
        - Keep each balloon's meaning. Don't add, drop or soften anything.
        - Work out who is speaking, and keep each speaker's tone and politeness consistent.
        - Keep names and terms the same throughout; fix mistranslated slang and wordplay.
        - Keep each translation about as long as it is now, so it fits its balloon.

        Reply with a plain-text file listing every balloon — also the ones that are already right — one per line, in exactly this form, keeping each id:
        [id] translation
        If you can't make a file, put the same lines in a single code block, and nothing else.
        """, bundle: .localized)
    }

    /// The translations in a reply, by id. Lines the chat wrapped in list
    /// markers, quotes or code formatting still count; anything else is
    /// skipped. A later line for the same id wins.
    static func parse(_ reply: String) -> [String: String] {
        let pattern = /^[\s>*\-•`]*\[(p\d+-\d+)\][\s*:：.\-]*(.*?)[\s`*]*$/
        var found: [String: String] = [:]
        for row in reply.split(whereSeparator: \.isNewline) {
            guard let match = String(row).wholeMatch(of: pattern) else { continue }
            var text = String(match.2).trimmingCharacters(in: .whitespaces)
            // "→ translation" when the chat echoed the original.
            if let arrow = text.range(of: "→", options: .backwards) {
                text = String(text[arrow.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] where text.hasPrefix(open) && text.hasSuffix(close) && text.count > 1 {
                text = String(text.dropFirst().dropLast())
            }
            text = text.replacingOccurrences(of: " / ", with: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { found[String(match.1)] = text }
        }
        return found
    }

    /// What a reply changes: the balloons to give a new translation, how
    /// many came back as they were or matched nothing, and which of those
    /// sent didn't come back at all.
    struct Changes: Equatable, Sendable {
        var updates: [(line: Line, text: String)] = []
        var unchanged = 0
        var unknown = 0
        /// Ids sent that the reply left out, in reading order.
        var missing: [String] = []

        /// Balloons the reply covered.
        var returned: Int { updates.count + unchanged }

        static func == (a: Changes, b: Changes) -> Bool {
            a.updates.map(\.line.id) == b.updates.map(\.line.id) && a.updates.map(\.text) == b.updates.map(\.text)
                && a.unchanged == b.unchanged && a.unknown == b.unknown && a.missing == b.missing
        }
    }

    static func changes(from reply: [String: String], lines: [Line]) -> Changes {
        let byID = Dictionary(lines.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var changes = Changes()
        for (id, text) in reply.sorted(by: { $0.key.localizedStandardCompare($1.key) == .orderedAscending }) {
            guard let line = byID[id] else {
                changes.unknown += 1
                continue
            }
            if text == line.translation.trimmingCharacters(in: .whitespacesAndNewlines) {
                changes.unchanged += 1
            } else {
                changes.updates.append((line, text))
            }
        }
        changes.missing = lines.map(\.id).filter { reply[$0] == nil }
        return changes
    }

    /// One line of text per balloon: line breaks shown as " / ".
    private static func flattened(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " / ")
    }
}
