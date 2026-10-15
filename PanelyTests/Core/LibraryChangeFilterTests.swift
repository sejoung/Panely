import CoreServices
import Foundation
import Testing
@testable import Panely

/// Which FSEvents file events may change the sidebar tree (and so cost a full
/// rescan). Unclassifiable events must stay relevant.
struct LibraryChangeFilterTests {
    private let filter = LibraryChangeFilter(
        root: URL(fileURLWithPath: "/Lib", isDirectory: true),
        maxDepth: 3
    )

    private func flags(_ values: Int...) -> FSEventStreamEventFlags {
        FSEventStreamEventFlags(values.reduce(0, |))
    }

    private var createdFile: FSEventStreamEventFlags {
        flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated)
    }

    private var createdDirectory: FSEventStreamEventFlags {
        flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemCreated)
    }

    @Test func archiveAndFolderChangesWithinTheShownDepthAreRelevant() {
        #expect(filter.isRelevant(path: "/Lib/Vol01.cbz", flags: createdFile))
        #expect(filter.isRelevant(path: "/Lib/Series/Sub/Vol01.CBR", flags: createdFile))
        #expect(filter.isRelevant(path: "/Lib/Series", flags: createdDirectory))
        #expect(filter.isRelevant(path: "/Lib/Series/Sub/Deep", flags: flags(kFSEventStreamEventFlagItemIsDir, kFSEventStreamEventFlagItemRenamed)))
        #expect(filter.isRelevant(path: "/Lib/Series/Vol01.zip", flags: flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemRemoved)))
    }

    @Test func noiseTheTreeNeverShowsIsIgnored() {
        // Finder metadata, hidden folders and resource forks.
        #expect(!filter.isRelevant(path: "/Lib/.DS_Store", flags: createdFile))
        #expect(!filter.isRelevant(path: "/Lib/Series/.DS_Store", flags: flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)))
        #expect(!filter.isRelevant(path: "/Lib/.git/objects", flags: createdDirectory))
        #expect(!filter.isRelevant(path: "/Lib/Series/__MACOSX", flags: createdDirectory))
        // Unsupported files, and pages inside a folder book below the tree.
        #expect(!filter.isRelevant(path: "/Lib/notes.txt", flags: createdFile))
        #expect(!filter.isRelevant(path: "/Lib/A/B/C/001.jpg", flags: createdFile))
        #expect(!filter.isRelevant(path: "/Lib/A/B/C/D", flags: createdDirectory))
        // Rewriting an archive's contents doesn't change the tree.
        #expect(!filter.isRelevant(path: "/Lib/Vol01.cbz", flags: flags(kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemModified)))
    }

    @Test func unclassifiableEventsStillRescan() {
        // Dropped history / root changes.
        #expect(filter.isRelevant(path: "/Lib/A/B/C/D/x.txt", flags: flags(kFSEventStreamEventFlagMustScanSubDirs)))
        #expect(filter.isRelevant(path: "/Lib", flags: flags(kFSEventStreamEventFlagRootChanged)))
        // No item kind, symlinks, the root itself, and paths outside it.
        #expect(filter.isRelevant(path: "/Lib/x.txt", flags: flags(kFSEventStreamEventFlagItemCreated)))
        #expect(filter.isRelevant(path: "/Lib/link", flags: flags(kFSEventStreamEventFlagItemIsSymlink, kFSEventStreamEventFlagItemIsFile, kFSEventStreamEventFlagItemCreated)))
        #expect(filter.isRelevant(path: "/Lib", flags: createdDirectory))
        #expect(filter.isRelevant(path: "/Elsewhere/.DS_Store", flags: createdFile))
    }

    @Test func rootPrefixDoesNotMatchASiblingWithTheSameStem() {
        #expect(filter.isRelevant(path: "/Library/.DS_Store", flags: createdFile))
    }
}
