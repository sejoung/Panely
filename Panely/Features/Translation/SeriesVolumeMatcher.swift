import Foundation

/// Decides which neighbouring books are volumes of the same series, for
/// "Translate Entire Series".
///
/// The reader's volume navigation treats every book in the same folder as a
/// sibling, which is fine for stepping to the next one but far too loose for
/// queuing hundreds of pages of translation: a "Comics" folder holding two
/// unrelated works would count as one two-volume series. Here a neighbour
/// counts only if its title, with volume numbering stripped, matches the open
/// book's — "One Piece v01" / "One Piece v02 (Digital)", "세평유 1화" /
/// "세평유 2화", "01" / "02".
nonisolated enum SeriesVolumeMatcher {
    static func volumes(matching book: URL, among siblings: [URL]) -> [URL] {
        let stem = titleStem(book.lastPathComponent)
        let current = book.standardizedFileURL
        return siblings.filter {
            $0.standardizedFileURL != current && titleStem($0.lastPathComponent) == stem
        }
    }

    /// A book's title with what varies between volumes removed: the file
    /// extension, bracketed tags, volume/chapter markers and their numbers,
    /// punctuation and spacing. Purely numbered names ("01.cbz") stem to "".
    static func titleStem(_ name: String) -> String {
        var title = name
        let ext = (name as NSString).pathExtension.lowercased()
        if ArchiveLoader.supportedExtensions.contains(ext) {
            title = (name as NSString).deletingPathExtension
        }
        title = title.lowercased()
        title = title.replacing(Patterns.releaseTags, with: " ")
        title = title.replacing(Patterns.markedVolume, with: " ")
        title = title.replacing(Patterns.countedVolume, with: " ")
        title = title.replacing(Patterns.ordinalVolume, with: " ")
        title = title.replacing(Patterns.numbers, with: " ")
        return title.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    /// Compiled once — the toolbar asks for the series' volumes as it
    /// renders. `Regex` isn't `Sendable`; these are only ever read.
    private enum Patterns {
        /// [Group] (Digital) {tag} 【…】 — release tags, not the title.
        nonisolated(unsafe) static let releaseTags = try! Regex(#"[\[\(\{【（][^\]\)\}】）]*[\]\)\}】）]"#)
        /// Volume/chapter markers next to a number: v01, vol.2, ch 10, #3, 1권, 2화, 3巻, 4話…
        nonisolated(unsafe) static let markedVolume = try! Regex(#"(?:volume|vol|ch(?:apter)?|ep(?:isode)?|v|#)\s*\.?\s*[0-9０-９]+"#)
        nonisolated(unsafe) static let countedVolume = try! Regex(#"[0-9０-９]+\s*(?:권|화|부|巻|話|卷|集)"#)
        nonisolated(unsafe) static let ordinalVolume = try! Regex(#"(?:제|第)\s*[0-9０-９]+"#)
        /// Remaining numbers (ranges like 1-294 included) and separators.
        nonisolated(unsafe) static let numbers = try! Regex(#"[0-9０-９]+"#)
    }
}
