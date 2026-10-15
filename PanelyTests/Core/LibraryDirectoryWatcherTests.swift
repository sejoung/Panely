import CoreServices
import Foundation
import Testing
@testable import Panely

/// `LibraryChangeFilter` against the flag combinations FSEvents actually
/// delivers for everyday file operations (as observed with
/// `kFSEventStreamCreateFlagFileEvents`), plus a real
/// `LiveLibraryDirectoryWatcher` on a temp directory end to end.
struct LibraryChangeFilterRealFlagsTests {

    private static let root = URL(fileURLWithPath: "/Lib", isDirectory: true)
    private let filter = LibraryChangeFilter(root: Self.root, maxDepth: 3)

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let path: String
        let flags: Int
        let relevant: Bool
        var testDescription: String { name }
    }

    private static let file = kFSEventStreamEventFlagItemIsFile
    private static let dir = kFSEventStreamEventFlagItemIsDir
    private static let created = kFSEventStreamEventFlagItemCreated
    private static let removed = kFSEventStreamEventFlagItemRemoved
    private static let renamed = kFSEventStreamEventFlagItemRenamed
    private static let modified = kFSEventStreamEventFlagItemModified
    private static let inodeMeta = kFSEventStreamEventFlagItemInodeMetaMod
    private static let xattr = kFSEventStreamEventFlagItemXattrMod
    private static let owner = kFSEventStreamEventFlagItemChangeOwner
    private static let finderInfo = kFSEventStreamEventFlagItemFinderInfoMod
    private static let cloned = kFSEventStreamEventFlagItemCloned

    static let cases: [Case] = [
        // Books appearing, disappearing, moving.
        Case(name: "Finder copy of an archive", path: "/Lib/Vol01.cbz",
             flags: file | created | modified | inodeMeta | xattr | owner, relevant: true),
        Case(name: "Finder duplicate (APFS clone)", path: "/Lib/Series/Vol01 copy.cbz",
             flags: file | created | cloned | inodeMeta, relevant: true),
        Case(name: "archive moved to Trash", path: "/Lib/Series/Vol02.cbr",
             flags: file | renamed, relevant: true),
        Case(name: "archive deleted", path: "/Lib/Series/Sub/Vol03.zip",
             flags: file | removed, relevant: true),
        Case(name: "download finishing (rename to .cbz)", path: "/Lib/Vol04.cbz",
             flags: file | renamed | xattr, relevant: true),
        Case(name: "new series folder", path: "/Lib/New Series",
             flags: dir | created, relevant: true),
        Case(name: "folder renamed at the deepest listed level", path: "/Lib/A/B/C",
             flags: dir | renamed, relevant: true),
        Case(name: "folder deleted", path: "/Lib/Old",
             flags: dir | removed | inodeMeta, relevant: true),
        // Metadata-only churn on a listed archive.
        Case(name: "Finder tag on an archive", path: "/Lib/Vol01.cbz",
             flags: file | xattr, relevant: false),
        Case(name: "touch / mtime change", path: "/Lib/Vol01.cbz",
             flags: file | inodeMeta, relevant: false),
        Case(name: "permissions / owner change", path: "/Lib/Vol01.cbz",
             flags: file | owner | inodeMeta, relevant: false),
        Case(name: "Finder info (label) change", path: "/Lib/Vol01.cbz",
             flags: file | finderInfo, relevant: false),
        Case(name: "archive rewritten in place", path: "/Lib/Vol01.cbz",
             flags: file | modified | inodeMeta, relevant: false),
        // Noise the tree never shows.
        Case(name: ".DS_Store atomic rewrite", path: "/Lib/Series/.DS_Store",
             flags: file | created | removed | renamed | modified | inodeMeta, relevant: false),
        Case(name: "AppleDouble companion", path: "/Lib/._Vol01.cbz",
             flags: file | created | xattr, relevant: false),
        Case(name: "partial download", path: "/Lib/Vol05.cbz.part",
             flags: file | created | modified, relevant: false),
        Case(name: "page image inside a folder book", path: "/Lib/Series/Vol01/001.jpg",
             flags: file | created | modified, relevant: false),
        Case(name: "archive below the listed depth", path: "/Lib/A/B/C/Vol.cbz",
             flags: file | created, relevant: false),
        Case(name: "folder below the listed depth", path: "/Lib/A/B/C/D",
             flags: dir | created, relevant: false),
        Case(name: "sync daemon's hidden folder", path: "/Lib/.sync/tmp",
             flags: dir | created, relevant: false),
        Case(name: "resource fork folder", path: "/Lib/Series/__MACOSX",
             flags: dir | created, relevant: false),
        // History the batch can't describe: always rescan.
        Case(name: "user-space drop", path: "/Lib/.DS_Store",
             flags: kFSEventStreamEventFlagUserDropped, relevant: true),
        Case(name: "kernel drop", path: "/Lib/A/B/C/D/x.jpg",
             flags: kFSEventStreamEventFlagKernelDropped, relevant: true),
        Case(name: "coalesced subtree", path: "/Lib/Series",
             flags: kFSEventStreamEventFlagMustScanSubDirs | dir, relevant: true),
        Case(name: "volume unmounted", path: "/Lib",
             flags: kFSEventStreamEventFlagUnmount, relevant: true),
    ]

    @Test(arguments: cases)
    func classifiesRealFlagCombinations(_ testCase: Case) {
        #expect(
            filter.isRelevant(path: testCase.path, flags: FSEventStreamEventFlags(testCase.flags)) == testCase.relevant
        )
    }

    /// FSEvents reports real paths. A root reached through a symlink
    /// (`/var` → `/private/var`, a symlinked library) must still be
    /// recognised, or every event — `.DS_Store` included — falls through to
    /// "unknown path, rescan".
    @Test func eventsUnderTheResolvedRootAreClassified() throws {
        let work = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: work) }
        let real = work.appendingPathComponent("Real", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = work.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let filter = LibraryChangeFilter(root: link, maxDepth: 3)
        let reported = real.resolvingSymlinksInPath().path
        let createdFile = FSEventStreamEventFlags(Self.file | Self.created)
        #expect(!filter.isRelevant(path: reported + "/.DS_Store", flags: createdFile))
        #expect(!filter.isRelevant(path: reported + "/A/B/C/D/x.cbz", flags: createdFile))
        #expect(filter.isRelevant(path: reported + "/Vol01.cbz", flags: createdFile))
    }
}

/// A real FSEvents stream on a temp directory: noise stays quiet, a new
/// archive or folder fires. Each wait is bounded; the FSEvents latency is
/// 1 s, so the quiet window waits 2.5 s.
///
/// The stream is created with `kFSEventStreamCreateFlagIgnoreSelf` (the
/// app's own extractions and cache writes must not rescan the library), so
/// every change here is made by a child process, as Finder or a sync client
/// would.
@MainActor
@Suite(.serialized, .enabled(if: TestTier.slow, TestTier.slowReason))
struct LiveLibraryDirectoryWatcherTests {

    @Test func firesForNewBooksAndFoldersButNotForNoise() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        // Created before watching: only what happens afterwards counts.
        let deep = root.appendingPathComponent("A/B/C/D", isDirectory: true)
        try FileManager.default.createDirectory(at: deep, withIntermediateDirectories: true)
        let series = root.appendingPathComponent("Series", isDirectory: true)
        try FileManager.default.createDirectory(at: series, withIntermediateDirectories: true)

        let watcher = LiveLibraryDirectoryWatcher()
        let counter = EventCounter()
        watcher.startWatching(root: root) { counter.count += 1 }
        defer { watcher.stopWatching() }
        try await Task.sleep(for: .milliseconds(500))
        counter.count = 0

        try externally(touch: [
            root.appendingPathComponent(".DS_Store"),
            series.appendingPathComponent(".DS_Store"),
            root.appendingPathComponent("notes.txt"),
            deep.appendingPathComponent("001.jpg"),
            deep.appendingPathComponent("Deep.cbz"),
        ])
        try await Task.sleep(for: .milliseconds(2500))
        #expect(counter.count == 0, "noise the tree never shows must not trigger a rescan")

        try externally(touch: [series.appendingPathComponent("Vol01.cbz")])
        try await waitUntil { counter.count > 0 }

        let afterArchive = counter.count
        try externally(mkdir: root.appendingPathComponent("A/New Series", isDirectory: true))
        try await waitUntil { counter.count > afterArchive }
    }

    @Test func stoppedWatcherNeverCallsBack() async throws {
        let root = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let watcher = LiveLibraryDirectoryWatcher()
        let counter = EventCounter()
        watcher.startWatching(root: root) { counter.count += 1 }
        try await Task.sleep(for: .milliseconds(300))
        try externally(touch: [root.appendingPathComponent("Vol01.cbz")])
        watcher.stopWatching()
        try await Task.sleep(for: .milliseconds(1800))
        #expect(counter.count == 0)
    }
}

/// Run a file operation in a child process (paths passed as arguments,
/// never interpolated into the script).
private func externally(touch urls: [URL]) throws {
    try runShell("touch \"$@\"", urls.map(\.path))
}

private func externally(mkdir url: URL) throws {
    try runShell("mkdir -p \"$1\"", [url.path])
}

private func runShell(_ script: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", script, "sh"] + arguments
    try process.run()
    process.waitUntilExit()
    try #require(process.terminationStatus == 0)
}

@MainActor
private final class EventCounter {
    var count = 0
}
