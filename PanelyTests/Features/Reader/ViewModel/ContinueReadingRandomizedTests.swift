import Testing
import Foundation
@testable import Panely

/// Fixed-seed random operation sequences against the incremental Continue
/// Reading index (`ContinueReadingIndexMemo` + `ContinueReadingMemo`),
/// checked after every step against the original full scan (the reference
/// below re-derives everything — keys, file identities, candidates — from
/// scratch each time). Operations cover page turns, finishing and
/// restarting books, removals, recents re-records/renames/removals/eviction,
/// source moves with path migration, files replaced on disk, folder children
/// vanishing and returning, availability refreshes and library refresh
/// tokens.
///
/// Every on-disk change is followed by a library refresh-token bump, the way
/// the directory watcher reports it in the app; the memo is allowed to keep
/// file identities until then.
@MainActor
@Suite(.serialized)
struct ContinueReadingRandomizedTests {

    @Test(arguments: TestTier.seeds([1, 7, 42, 2024, 99_991, 31_337, 8_675_309, 65_537]))
    func incrementalSuggestionMatchesFullScan(seed: UInt64) async throws {
        var rng = SplitMix64(seed: seed)
        let world = try World()
        defer { world.tearDown() }
        let vm = world.vm

        for step in 0..<250 {
            let label = try await world.performRandomOperation(using: &rng)
            check(vm, "seed \(seed) step \(step): \(label)")
        }
    }

    private func check(_ vm: ReaderViewModel, _ label: String) {
        let actual = vm.continueReadingSuggestion
        let expected = referenceSuggestion(vm)
        let comment = Comment(rawValue: label)
        #expect(actual?.id == expected?.id, comment)
        #expect(actual?.title == expected?.title, comment)
        #expect(actual?.fraction == expected?.fraction, comment)
        #expect(actual?.relativePath == expected?.relativePath, comment)
        #expect(actual?.fileIdentityKey == expected?.fileIdentityKey, comment)
        #expect(actual?.item.id == expected?.item.id, comment)
    }

    // MARK: - World

    @MainActor
    final class World {
        let root: URL
        let vm: ReaderViewModel
        let clock = TickingClock()
        /// Sources that can be recents, by name.
        var sources: [String: URL]
        var fillerCount = 0
        let folderChildren = ["Vol01", "Vol02", "Vol03"]

        init() throws {
            root = try Fixture.makeTempDir()
            let folder = root.appendingPathComponent("Folder", isDirectory: true)
            for name in ["Vol01", "Vol02"] {
                let volume = folder.appendingPathComponent(name, isDirectory: true)
                try FileManager.default.createDirectory(at: volume, withIntermediateDirectories: true)
                try Fixture.writeFile(volume.appendingPathComponent("001.jpg"))
            }
            sources = [
                "Series": try Fixture.writeFile(root.appendingPathComponent("Series.cbz")),
                "Single": try Fixture.writeFile(root.appendingPathComponent("Single.cbz")),
                "Other": try Fixture.writeFile(root.appendingPathComponent("Other.cbz")),
                "Folder": folder,
                "FolderVol01": folder.appendingPathComponent("Vol01", isDirectory: true),
            ]

            let keyValueStore = InMemoryKeyValueStore()
            let base = makeTestDependencies(keyValueStore: keyValueStore)
            let clock = clock
            vm = ReaderViewModel(dependencies: AppDependencies(
                extractionCache: base.extractionCache,
                bookmarkResolver: base.bookmarkResolver,
                libraryTreeLoader: base.libraryTreeLoader,
                keyValueStore: base.keyValueStore,
                systemSettings: base.systemSettings,
                sourceChangeMonitorFactory: base.sourceChangeMonitorFactory,
                libraryDirectoryWatcherFactory: base.libraryDirectoryWatcherFactory,
                libraryAutoRefreshEnabled: base.libraryAutoRefreshEnabled,
                filePickerFactory: base.filePickerFactory,
                localization: base.localization,
                translationStore: base.translationStore,
                translationEditStore: base.translationEditStore,
                translator: base.translator,
                makeTranslationModelStore: base.makeTranslationModelStore,
                makePageAnalyzer: base.makePageAnalyzer,
                makeReaderPreferences: base.makeReaderPreferences,
                makeReaderPositions: base.makeReaderPositions,
                // Strictly increasing timestamps: no ties, so the expected
                // winner never depends on scan order.
                makeReadingProgress: { ReadingProgressStore(defaults: keyValueStore, clock: { clock.next() }) },
                makeLastLibraryRoot: base.makeLastLibraryRoot,
                makeReaderTempDirectory: base.makeReaderTempDirectory,
                makeReaderLibraryScope: base.makeReaderLibraryScope
            ))
            for name in ["Folder", "Other", "Single", "Series"] {
                vm.recentItems.record(sources[name]!, title: name)
            }
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        var folder: URL { sources["Folder"]! }

        /// Every key a record may land under right now: source keys, archive
        /// inner volumes (incl. the empty inner path), folder children (one
        /// never on disk, one with a nested `#`), file-identity aliases of
        /// each, and a book belonging to no recent.
        func progressKeys() -> [(key: String, alias: String?)] {
            var keys: [(String, String?)] = []
            // Sorted: dictionary order is seeded per process, and the
            // sequence must replay identically for a given seed.
            for name in sources.keys.sorted() {
                let derived = PositionKey.keys(for: sources[name]!, opened: nil, tempRoot: nil)
                keys.append((derived.primary, derived.fileIdentity))
                if let fid = derived.fileIdentity { keys.append((fid, nil)) }
            }
            let series = PositionKey.keys(for: sources["Series"]!, opened: nil, tempRoot: nil)
            for inner in ["Vol01", "Vol02", "Vol03", ""] {
                keys.append((series.primary + "#" + inner, series.fileIdentity.map { $0 + "#" + inner }))
            }
            if let fid = series.fileIdentity { keys.append((fid + "#Vol01", nil)) }
            let folderPath = folder.standardizedFileURL.path
            for child in folderChildren {
                let childURL = folder.appendingPathComponent(child, isDirectory: true)
                let fid = PositionKey.fileIdentity(for: childURL)
                keys.append((folderPath + "/" + child, fid))
                if let fid { keys.append((fid, nil)) }
            }
            keys.append((folderPath + "/Vol02#inner", nil))
            keys.append(("/elsewhere/Unrelated.cbz", nil))
            keys.append((Self.strayPath + "#Vol09", nil))
            keys.append((Self.strayPath + "/Vol09", nil))
            return keys
        }

        /// A book outside every recent whose records get re-filed under one.
        static let strayPath = "/elsewhere/Moved Away.cbz"

        func performRandomOperation(using rng: inout SplitMix64) async throws -> String {
            let progress = vm.readingProgress
            let roll = Int.random(in: 0..<100, using: &rng)
            switch roll {
            case 0..<34:
                let (key, alias) = progressKeys().randomElement(using: &rng)!
                let page = Int.random(in: 0..<20, using: &rng)
                let finished = Int.random(in: 0..<7, using: &rng) == 0
                if Bool.random(using: &rng) {
                    progress.flushImmediately(forKey: key, fileIdentityKey: alias, page: page, total: 20, finished: finished)
                } else {
                    // Debounced, landing on the next flush (or never, if
                    // superseded by the same key) — like a page turn.
                    progress.record(forKey: key, fileIdentityKey: alias, page: page, total: 20, finished: finished)
                    if Bool.random(using: &rng) { progress.saveDebouncer.flush() }
                }
                return "write \(key) page \(page)\(finished ? " finished" : "")"
            case 34..<40:
                let (key, alias) = progressKeys().randomElement(using: &rng)!
                progress.resetCompletion(forKey: key, fileIdentityKey: alias, page: 0, total: 20)
                return "restart \(key)"
            case 40..<45:
                let (key, alias) = progressKeys().randomElement(using: &rng)!
                progress.remove(forKey: key, fileIdentityKey: Bool.random(using: &rng) ? alias : nil)
                return "remove \(key)"
            case 45..<53:
                let name = sources.keys.sorted().randomElement(using: &rng)!
                let title = Bool.random(using: &rng) ? name : name + " (renamed)"
                vm.recentItems.record(sources[name]!, title: title)
                return "record recent \(name) as \(title)"
            case 53..<58:
                guard let item = vm.recentItems.items.randomElement(using: &rng) else { return "remove recent (none)" }
                vm.recentItems.remove(item)
                return "remove recent \(item.title)"
            case 58..<62:
                return try moveSource(using: &rng)
            case 62..<66:
                return try await replaceSourceOnDisk(using: &rng)
            case 66..<71:
                return try toggleFolderChildOnDisk(using: &rng)
            case 71..<79:
                await vm.refreshContinueReadingAvailability()
                return "refresh availability"
            case 79..<84:
                vm.refreshLibraryTree(checkingAvailability: false)
                return "refresh token"
            case 84..<86:
                // Evict everything older from the 50-item recents list.
                for _ in 0..<50 {
                    fillerCount += 1
                    vm.recentItems.record(
                        URL(fileURLWithPath: "/nonexistent/filler-\(fillerCount).cbz"),
                        title: "Filler \(fillerCount)"
                    )
                }
                return "flood recents"
            case 86..<88:
                // A page-bookmark ref resolving to a recent source's path
                // re-files progress without touching recents.
                let target = ["Series", "Folder"].randomElement(using: &rng)!
                progress.migrateSourcePath(from: Self.strayPath, to: sources[target]!.standardizedFileURL.path)
                return "migrate stray records into \(target)"
            case 88..<90:
                let name = sources.keys.sorted().randomElement(using: &rng)!
                progress.removeEntries(forSourcePath: sources[name]!.standardizedFileURL.path)
                return "forget source \(name)"
            default:
                // Let a pending debounced write land (or not) between checks.
                progress.saveDebouncer.flush()
                vm.positions.saveDebouncer.flush()
                return "flush"
            }
        }

        /// Rename a source on disk and follow it the way a resolved bookmark
        /// does: migrate keys, re-record the recent at its new path.
        private func moveSource(using rng: inout SplitMix64) throws -> String {
            let name = ["Single", "Other", "Series"].randomElement(using: &rng)!
            let old = sources[name]!
            let base = old.deletingPathExtension().lastPathComponent
            let newName = base.hasSuffix("-moved") ? String(base.dropLast(6)) : base + "-moved"
            let new = old.deletingLastPathComponent().appendingPathComponent(newName + ".cbz")
            try FileManager.default.moveItem(at: old, to: new)
            sources[name] = new
            vm.applyRecentItemMigration(RecentItemPathMigration(
                oldPath: old.standardizedFileURL.path,
                newPath: new.standardizedFileURL.path
            ))
            if let item = vm.recentItems.items.first(where: { $0.path == old.standardizedFileURL.path }) {
                vm.recentItems.remove(item)
                vm.recentItems.record(new, title: item.title)
            }
            vm.refreshLibraryTree(checkingAvailability: false)
            return "move \(name) → \(new.lastPathComponent)"
        }

        /// Same path, new inode: the file identity changes.
        private func replaceSourceOnDisk(using rng: inout SplitMix64) async throws -> String {
            let name = ["Single", "Other", "Series"].randomElement(using: &rng)!
            let url = sources[name]!
            // An atomic save: a new inode (deleting first could reuse it).
            try Data([UInt8.random(in: 0...255, using: &rng)]).write(to: url, options: .atomic)
            // Resource values (the file identity) are cached per `URL` until
            // the next run-loop pass — as there is before the watcher fires.
            try await Task.sleep(for: .milliseconds(5))
            vm.refreshLibraryTree(checkingAvailability: false)
            return "replace \(name) on disk"
        }

        private func toggleFolderChildOnDisk(using rng: inout SplitMix64) throws -> String {
            let child = folder.appendingPathComponent("Vol02", isDirectory: true)
            if FileManager.default.fileExists(atPath: child.path) {
                try FileManager.default.removeItem(at: child)
                vm.refreshLibraryTree(checkingAvailability: false)
                return "delete Folder/Vol02"
            }
            try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
            try Fixture.writeFile(child.appendingPathComponent("001.jpg"))
            vm.refreshLibraryTree(checkingAvailability: false)
            return "restore Folder/Vol02"
        }
    }

    @MainActor
    final class TickingClock {
        private var tick: Double = 0
        func next() -> Date {
            tick += 1
            return Date(timeIntervalSinceReferenceDate: 800_000_000 + tick)
        }
    }

    struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    // MARK: - Reference: the original full scan
    //
    // Same algorithm as `ContinueReadingIndexTests.referenceSuggestion`
    // (duplicated so the two suites stay independent).

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
