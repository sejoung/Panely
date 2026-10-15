import Testing
import Foundation
import ZIPFoundation
@testable import Panely

/// `ArchiveLoader.hasNestedArchives` hands its open reader + listing to the
/// `load(from:)` that follows, through a process-wide one-slot handoff. The
/// handoff is an optimisation only: a load must list exactly what a fresh
/// open of that file would — never another file's entries, never a listing
/// taken before the file changed.
///
/// `.serialized`: the slot is shared, so these tests mustn't hand listings
/// to each other. (Other suites using `ArchiveLoader` concurrently can only
/// *empty* the slot, which forces a fresh open — still correct.)
@Suite(.serialized)
struct ArchiveLoaderHandoffTests {
    /// Two different books that happen to match in size and mtime (same
    /// page count and name lengths, copied with preserved timestamps): the
    /// signature can't tell them apart, the path must.
    @Test func listingIsNeverHandedToADifferentArchive() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let first = try Self.makeZip(workDir.appendingPathComponent("a.cbz"), entries: ["01.jpg", "02.jpg"])
        let second = try Self.makeZip(workDir.appendingPathComponent("b.cbz"), entries: ["x1.jpg", "x2.jpg"])
        try #require(ComicPage.contentSignature(for: first) == ComicPage.contentSignature(for: second))

        #expect(try await ArchiveLoader.hasNestedArchives(at: first) == false)
        let comic = try await ArchiveLoader.load(from: second)

        #expect(comic.pages.map(\.displayName) == ["x1.jpg", "x2.jpg"])
        #expect(comic.title == "b")
    }

    /// The slot is emptied by the load that takes it. A later load of the
    /// same path opens the file again — even when its size + mtime look
    /// unchanged (a sync tool restoring timestamps, a same-size rewrite),
    /// which the signature check alone couldn't tell apart.
    @Test func handedOverListingIsUsedOnlyOnce() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("book.cbz")
        let stamp = Date(timeIntervalSince1970: 1_600_000_000)

        try Self.makeZip(url, entries: ["01.jpg", "02.jpg"], stamp: stamp)
        let signature = ComicPage.contentSignature(for: url)
        #expect(try await ArchiveLoader.hasNestedArchives(at: url) == false)
        let firstLoad = try await ArchiveLoader.load(from: url)
        #expect(firstLoad.pages.map(\.displayName) == ["01.jpg", "02.jpg"])

        try FileManager.default.removeItem(at: url)
        try Self.makeZip(url, entries: ["01.jpg", "03.jpg"], stamp: stamp)
        try #require(ComicPage.contentSignature(for: url) == signature, "fixture should rewrite the file with the same size + mtime")

        let secondLoad = try await ArchiveLoader.load(from: url)
        #expect(secondLoad.pages.map(\.displayName) == ["01.jpg", "03.jpg"])
    }

    // MARK: - Page ids (content signature computed once per archive)

    /// `load` stats the archive once and stamps every page with that
    /// signature; the ids must be exactly what a page computing its own
    /// signature gets — thumbnails, translations and bookmarks are keyed by
    /// them.
    @Test func archivePageIDsMatchSelfComputedIDs() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = try Self.makeZip(workDir.appendingPathComponent("book.cbz"), entries: ["01.jpg", "02.jpg", "10.jpg"])

        let comic = try await ArchiveLoader.load(from: url)

        #expect(comic.pages.count == 3)
        for page in comic.pages {
            let selfComputed = ComicPage(source: page.source, displayName: page.displayName)
            #expect(page.id == selfComputed.id)
        }
    }

    /// Replacing the archive in place changes every page id — including
    /// pages whose entry path is unchanged — so caches keyed by id can't
    /// serve the old book's pixels.
    @Test func replacingTheArchiveChangesEveryPageID() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }
        let url = workDir.appendingPathComponent("book.cbz")

        try Self.makeZip(url, entries: ["01.jpg", "02.jpg"], stamp: Date(timeIntervalSince1970: 1_600_000_000))
        let before = try await ArchiveLoader.load(from: url)
        try FileManager.default.removeItem(at: url)
        try Self.makeZip(url, entries: ["01.jpg", "02.jpg", "03.jpg"], stamp: Date(timeIntervalSince1970: 1_600_000_100))
        let after = try await ArchiveLoader.load(from: url)

        #expect(Set(before.pages.map(\.id)).isDisjoint(with: after.pages.map(\.id)))
    }

    // MARK: - Nested-archive detection

    @Test func nestedArchiveDetectionMatchesExtensionsCaseInsensitivelyAtAnyDepth() async throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let deepUpper = try Self.makeZip(workDir.appendingPathComponent("a.cbz"), entries: ["covers/01.jpg", "Series/Vol 01.CBR"])
        let plainZip = try Self.makeZip(workDir.appendingPathComponent("b.cbz"), entries: ["Vol 02.zip"])
        let onlyMetadata = try Self.makeZip(
            workDir.appendingPathComponent("c.cbz"),
            entries: ["01.jpg", "__MACOSX/._Vol 01.cbz", ".hidden/Vol 02.rar", "notes/.Vol 03.cbz"]
        )
        let lookalikes = try Self.makeZip(workDir.appendingPathComponent("d.cbz"), entries: ["cbz.jpg", "Vol.cbz.txt"])

        #expect(try await ArchiveLoader.hasNestedArchives(at: deepUpper))
        #expect(try await ArchiveLoader.hasNestedArchives(at: plainZip))
        #expect(try await ArchiveLoader.hasNestedArchives(at: onlyMetadata) == false)
        #expect(try await ArchiveLoader.hasNestedArchives(at: lookalikes) == false)
    }

    // MARK: - Fixture

    /// A ZIP of `entries`, each holding `payload(for:)`. Entry timestamps and
    /// the file's mtime are `stamp`, so two archives with same-length names
    /// come out the same size with the same signature.
    @discardableResult
    static func makeZip(_ url: URL, entries: [String], stamp: Date = Date(timeIntervalSince1970: 1_600_000_000)) throws -> URL {
        let archive = try Archive(url: url, accessMode: .create)
        for path in entries {
            let data = payload(for: (path as NSString).lastPathComponent)
            try archive.addEntry(
                with: path,
                type: .file,
                uncompressedSize: Int64(data.count),
                modificationDate: stamp,
                provider: { position, size in data.subdata(in: Int(position)..<Int(position) + size) }
            )
        }
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: url.path)
        return url
    }

    /// Same length for every name, distinct bytes per name.
    static func payload(for name: String) -> Data {
        Data((name + String(repeating: "#", count: max(0, 32 - name.count))).utf8.prefix(32))
    }
}
