import Testing
import Foundation
@testable import Panely

/// `continueReadingSuggestion` caches which progress keys belong to which
/// recent source and only re-reads those records on a page turn. These tests
/// pin it to the original full-scan algorithm (kept below as the reference)
/// across a mixed library: archives with inner volumes, a container folder
/// with child volumes (one missing on disk), file-identity aliases, finished
/// books, and records that belong to no recent source.
@MainActor
struct ContinueReadingIndexTests {

    @Test func cachedIndexMatchesFullScanAcrossMutations() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let series = try Fixture.writeFile(root.appendingPathComponent("Series.cbz"))
        let single = try Fixture.writeFile(root.appendingPathComponent("Single.cbz"))
        let folder = root.appendingPathComponent("Folder", isDirectory: true)
        for name in ["Vol01", "Vol02"] {
            let volume = folder.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
            try Fixture.writeFile(volume.appendingPathComponent("001.jpg"))
        }

        let vm = makeTestViewModel()
        vm.recentItems.record(folder, title: "Folder")
        vm.recentItems.record(single, title: "Single")
        vm.recentItems.record(series, title: "Series")
        let progress = vm.readingProgress
        let seriesPath = series.standardizedFileURL.path
        let folderPath = folder.standardizedFileURL.path
        let seriesIdentity = try #require(PositionKey.fileIdentity(for: series))

        func write(_ key: String, alias: String? = nil, page: Int, total: Int = 20, finished: Bool = false) {
            progress.flushImmediately(forKey: key, fileIdentityKey: alias, page: page, total: total, finished: finished)
        }
        func check(_ label: Comment) {
            let actual = vm.continueReadingSuggestion
            let expected = referenceSuggestion(vm)
            #expect(actual?.id == expected?.id, label)
            #expect(actual?.title == expected?.title, label)
            #expect(actual?.fraction == expected?.fraction, label)
            #expect(actual?.relativePath == expected?.relativePath, label)
            #expect(actual?.fileIdentityKey == expected?.fileIdentityKey, label)
            #expect(actual?.item.id == expected?.item.id, label)
        }

        check("empty")
        write("/elsewhere/Unrelated.cbz", page: 3)
        check("only an unrelated record")
        write(seriesPath + "#Vol01", alias: seriesIdentity + "#Vol01", page: 4)
        write(seriesPath + "#Vol02", page: 1)
        write(seriesPath + "#", page: 2)
        check("archive inner volumes")
        #expect(vm.continueReadingSuggestion?.relativePath == "Vol02")
        write(single.standardizedFileURL.path, page: 5)
        check("plain archive is freshest")
        write(folderPath + "/Vol01", page: 6)
        write(folderPath + "/Vol03", page: 7)
        write(folderPath + "/Vol02#inner", page: 8)
        check("folder children, one missing")
        #expect(vm.continueReadingSuggestion?.relativePath == "Vol03")

        await vm.refreshContinueReadingAvailability()
        check("missing folder child hidden")
        #expect(vm.continueReadingSuggestion?.relativePath == "Vol01")

        // Page turns: existing records move, the key set doesn't.
        write(seriesPath + "#Vol02", page: 9)
        check("page turn in an inner volume")
        write(seriesIdentity + "#Vol01", page: 10)
        check("fresher file-identity alias wins")
        #expect(vm.continueReadingSuggestion?.id == seriesPath + "#Vol01")
        #expect(vm.continueReadingSuggestion?.fraction == 0.55)
        write(folderPath + "/Vol01", page: 19, finished: true)
        check("finishing a folder child")
        write(seriesPath + "#Vol01", alias: seriesIdentity + "#Vol01", page: 19, finished: true)
        write(seriesPath + "#Vol02", page: 19, finished: true)
        check("finishing every inner volume")

        // Key-set and recents changes.
        progress.remove(forKey: single.standardizedFileURL.path, fileIdentityKey: nil)
        check("removed record")
        vm.recentItems.record(single, title: "Single Renamed")
        write(single.standardizedFileURL.path, page: 2)
        check("re-recorded recent with new title")
        vm.recentItems.remove(try #require(vm.recentItems.items.first { $0.title == "Single Renamed" }))
        check("recent removed")
    }

    @Test func pageTurnReusesTheIndexButStillUpdatesTheSuggestion() {
        let vm = makeTestViewModel()
        let book = URL(fileURLWithPath: "/lib/book.cbz")
        vm.recentItems.record(book, title: "Book")
        let key = book.standardizedFileURL.path
        vm.readingProgress.flushImmediately(forKey: key, fileIdentityKey: nil, page: 1, total: 10, finished: false)
        #expect(vm.continueReadingSuggestion?.fraction == 0.2)
        let keysRevision = vm.readingProgress.keysRevision

        vm.readingProgress.flushImmediately(forKey: key, fileIdentityKey: nil, page: 4, total: 10, finished: false)

        // Moving an existing record leaves the key set (and so the index)
        // alone, yet the suggestion follows the new page.
        #expect(vm.readingProgress.keysRevision == keysRevision)
        #expect(vm.continueReadingSuggestion?.fraction == 0.5)
    }

    // MARK: - Reference: the original full scan

    private func referenceSuggestion(_ vm: ReaderViewModel) -> ReaderViewModel.ContinueReadingSuggestion? {
        struct Candidate {
            let key: String
            let title: String
            let fraction: Double
            let updatedAt: Date
            let item: RecentItem
            let relativePath: String?
            let fileIdentityKey: String?
        }
        let progressStore = vm.readingProgress
        func candidate(
            key: String,
            item: RecentItem,
            relativePath: String?,
            fileIdentityKey: String?,
            progress: ReadingProgress
        ) -> Candidate? {
            guard !progress.finished, progress.total > 0 else { return nil }
            let title = relativePath.map {
                "\(item.title) · \(vm.displayTitle(for: URL(fileURLWithPath: $0)))"
            } ?? item.title
            return Candidate(
                key: key,
                title: title,
                fraction: progress.fraction,
                updatedAt: progress.updatedAt,
                item: item,
                relativePath: relativePath,
                fileIdentityKey: fileIdentityKey
            )
        }
        func candidates(for item: RecentItem) -> [Candidate] {
            guard let url = vm.recentItems.availableURL(for: item) else { return [] }
            let keys = PositionKey.keys(for: url, opened: nil, tempRoot: nil)
            var result: [Candidate] = []
            var includedKeys: Set<String> = []
            if let progress = progressStore.mostRecentProgress(forKey: keys.primary, fileIdentityKey: keys.fileIdentity),
               let found = candidate(key: keys.primary, item: item, relativePath: nil, fileIdentityKey: keys.fileIdentity, progress: progress) {
                result.append(found)
                includedKeys.insert(keys.primary)
            }
            let nestedPrefix = keys.primary + "#"
            for (key, progress) in progressStore.entries where key.hasPrefix(nestedPrefix) {
                let relativePath = String(key.dropFirst(nestedPrefix.count))
                let fileIdentityKey = PositionKey.fileIdentity(for: url).map { $0 + "#" + relativePath }
                let freshest = progressStore.mostRecentProgress(forKey: key, fileIdentityKey: fileIdentityKey) ?? progress
                guard includedKeys.insert(key).inserted,
                      !relativePath.isEmpty,
                      let found = candidate(key: key, item: item, relativePath: relativePath, fileIdentityKey: fileIdentityKey, progress: freshest)
                else { continue }
                result.append(found)
            }
            if item.isDirectory {
                let childPrefix = keys.primary + "/"
                for (key, progress) in progressStore.entries where key.hasPrefix(childPrefix) && !key.contains("#") {
                    let relativePath = String(key.dropFirst(childPrefix.count))
                    let childURL = url.appendingPathComponent(relativePath).standardizedFileURL
                    let fileIdentityKey = PositionKey.fileIdentity(for: childURL)
                    let freshest = progressStore.mostRecentProgress(forKey: key, fileIdentityKey: fileIdentityKey) ?? progress
                    guard includedKeys.insert(key).inserted,
                          !relativePath.isEmpty,
                          url.isAncestor(of: childURL),
                          !vm.unavailableContinueReadingKeys.contains(key),
                          let found = candidate(key: key, item: item, relativePath: relativePath, fileIdentityKey: fileIdentityKey, progress: freshest)
                    else { continue }
                    result.append(found)
                }
            }
            return result
        }

        var best: Candidate?
        var bestUpdatedAt = Date.distantPast
        for item in vm.recentItems.items {
            for found in candidates(for: item) where found.updatedAt > bestUpdatedAt {
                bestUpdatedAt = found.updatedAt
                best = found
            }
        }
        return best.map {
            ReaderViewModel.ContinueReadingSuggestion(
                id: $0.key,
                title: $0.title,
                fraction: $0.fraction,
                item: $0.item,
                relativePath: $0.relativePath,
                fileIdentityKey: $0.fileIdentityKey
            )
        }
    }
}
