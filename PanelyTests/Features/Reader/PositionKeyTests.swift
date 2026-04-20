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
}
