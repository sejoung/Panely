import CryptoKit
import Foundation

/// The reader's balloon edits on disk (`PageEdits`), one small JSON file per
/// page and scope. Under Application Support, not Caches: unlike machine
/// translations these can't be made again, so "Clear Translation Cache"
/// leaves them alone; Settings deletes them separately.
nonisolated struct TranslationEditStore: Sendable {
    let root: URL

    init(root: URL = TranslationEditStore.defaultRoot()) {
        self.root = root
    }

    static func defaultRoot() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("panely-translation-edits", isDirectory: true)
    }

    /// The scope is part of the key, as for the cache: a slice read on its own
    /// and as part of a strip have different balloons. Languages and mode
    /// aren't — edits hold for whatever the book is shown in.
    static func key(pageID: String, scope: TranslationScope) -> String {
        let composite = "\(pageID)|\(scope.rawValue)"
        return SHA256.hash(data: Data(composite.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    func load(key: String) -> PageEdits? {
        guard let data = try? Data(contentsOf: fileURL(forKey: key)) else { return nil }
        return try? JSONDecoder().decode(PageEdits.self, from: data)
    }

    /// Saving a page with no edits left deletes its file.
    func save(_ edits: PageEdits, key: String) throws {
        let url = fileURL(forKey: key)
        guard !edits.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(edits).write(to: url, options: .atomic)
    }

    /// Pages with edits, across all books.
    func pageCount() -> Int {
        entries().count
    }

    func clear() {
        for url in entries() { try? FileManager.default.removeItem(at: url) }
    }

    private func fileURL(forKey key: String) -> URL {
        root.appendingPathComponent(key).appendingPathExtension("json")
    }

    private func entries() -> [URL] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
    }
}
