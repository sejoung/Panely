import Testing
import Foundation
@testable import Panely

struct PositionKeyTests {
    @Test func directOpenReturnsPlainPath() {
        let url = URL(fileURLWithPath: "/Comics/Vol01.cbz")
        let key = PositionKey.make(for: url, opened: nil, tempRoot: nil)
        #expect(key == "/Comics/Vol01.cbz")
    }

    @Test func tempBackedVolumeUsesCompoundKey() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-A/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/series.zip#Vol01.cbz")
    }

    @Test func tempRootMatchesOpenedPathDirectly() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")

        let key = PositionKey.make(for: temp, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/series.zip")
    }

    @Test func outsideTempFallsBackToSourcePath() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/other/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/other/Vol01.cbz")
    }

    @Test func deeplyNestedPathProducesRelativeSegments() {
        let opened = URL(fileURLWithPath: "/Comics/super.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-A/middle/Vol01")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/Comics/super.zip#middle/Vol01")
    }

    @Test func siblingPathWithSimilarPrefixIsNotCollapsed() {
        let opened = URL(fileURLWithPath: "/Comics/series.zip")
        let temp = URL(fileURLWithPath: "/tmp/panely-A")
        let source = URL(fileURLWithPath: "/tmp/panely-Abc/Vol01.cbz")

        let key = PositionKey.make(for: source, opened: opened, tempRoot: temp)
        #expect(key == "/tmp/panely-Abc/Vol01.cbz")
    }

    @Test func tempBackedKeysUseOuterIdentityAndInnerPath() throws {
        let workDir = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: workDir) }

        let opened = try Fixture.writeFile(workDir.appendingPathComponent("series.cbz"))
        let temp = workDir.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let source = temp.appendingPathComponent("Vol01.cbz")

        guard let openedIdentity = PositionKey.fileIdentity(for: opened) else {
            Issue.record("expected file identity for fixture archive")
            return
        }

        let keys = PositionKey.keys(for: source, opened: opened, tempRoot: temp)
        #expect(keys.primary == opened.standardizedFileURL.path + "#Vol01.cbz")
        #expect(keys.fileIdentity == openedIdentity + "#Vol01.cbz")
    }

    @Test func folderListedArchiveKeysUseEachVolumeIdentity() throws {
        let seriesFolder = try Fixture.makeTempDir()
        defer { try? FileManager.default.removeItem(at: seriesFolder) }

        let volumeOne = try Fixture.writeFile(seriesFolder.appendingPathComponent("Vol01.cbz"))
        let volumeTwo = try Fixture.writeFile(seriesFolder.appendingPathComponent("Vol02.cbz"))

        let keysOne = PositionKey.keys(for: volumeOne, opened: seriesFolder, tempRoot: nil)
        let keysTwo = PositionKey.keys(for: volumeTwo, opened: seriesFolder, tempRoot: nil)

        #expect(keysOne.primary == volumeOne.standardizedFileURL.path)
        #expect(keysTwo.primary == volumeTwo.standardizedFileURL.path)
        #expect(keysOne.fileIdentity == PositionKey.fileIdentity(for: volumeOne))
        #expect(keysTwo.fileIdentity == PositionKey.fileIdentity(for: volumeTwo))
        #expect(keysOne.fileIdentity != keysTwo.fileIdentity)
    }
}
