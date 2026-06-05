import Testing
import Foundation
@testable import Panely

/// `ReaderSeriesIdentity` groups books into the series across which per-series
/// reader state is shared. Mirrors the resolution `PositionKey` uses, but at
/// the series (container) level rather than the individual book.
struct ReaderSeriesIdentityTests {

    @Test func nilSourceHasNoSeries() {
        #expect(ReaderSeriesIdentity.make(for: nil, opened: nil, tempRoot: nil) == nil)
    }

    @Test func folderVolumesShareTheParentFolderSeries() {
        let dir = URL(fileURLWithPath: "/Library/Manga Series A")
        let vol1 = dir.appendingPathComponent("Vol01.cbz")
        let vol2 = dir.appendingPathComponent("Vol02.cbz")

        let s1 = ReaderSeriesIdentity.make(for: vol1, opened: nil, tempRoot: nil)
        let s2 = ReaderSeriesIdentity.make(for: vol2, opened: nil, tempRoot: nil)

        #expect(s1 == s2)
        #expect(s1 != nil)
    }

    @Test func differentParentFoldersAreDifferentSeries() {
        let a = URL(fileURLWithPath: "/Library/Series A/Vol01.cbz")
        let b = URL(fileURLWithPath: "/Library/Series B/Vol01.cbz")

        #expect(ReaderSeriesIdentity.make(for: a, opened: nil, tempRoot: nil)
                != ReaderSeriesIdentity.make(for: b, opened: nil, tempRoot: nil))
    }

    @Test func innerVolumesOfOneArchiveShareTheArchiveSeries() {
        // Two inner volumes extracted under a temp root from one outer archive
        // resolve to the same series (the archive), stable across sessions even
        // though the temp extraction dir is not.
        let archive = URL(fileURLWithPath: "/Downloads/Whole Series.cbz")
        let tempRoot = URL(fileURLWithPath: "/var/folders/extract-XYZ")
        let inner1 = tempRoot.appendingPathComponent("Vol01.cbz")
        let inner2 = tempRoot.appendingPathComponent("Vol02.cbz")

        let s1 = ReaderSeriesIdentity.make(for: inner1, opened: archive, tempRoot: tempRoot)
        let s2 = ReaderSeriesIdentity.make(for: inner2, opened: archive, tempRoot: tempRoot)

        #expect(s1 == s2)
        #expect(s1 == "series:" + archive.standardizedFileURL.path)
    }

    @Test func sourceOutsideTempRootKeysOnItsOwnParentNotTheArchive() {
        // A normal file with an unrelated opened/temp context (source not under
        // the temp root) falls back to its parent folder.
        let archive = URL(fileURLWithPath: "/Downloads/Other.cbz")
        let tempRoot = URL(fileURLWithPath: "/var/folders/extract-XYZ")
        let source = URL(fileURLWithPath: "/Library/Series C/Vol01.cbz")

        let series = ReaderSeriesIdentity.make(for: source, opened: archive, tempRoot: tempRoot)
        #expect(series == "series:" + source.deletingLastPathComponent().standardizedFileURL.path)
    }
}
