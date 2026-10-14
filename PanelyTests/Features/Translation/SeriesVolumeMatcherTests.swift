import Foundation
import Testing
@testable import Panely

struct SeriesVolumeMatcherTests {
    private func url(_ name: String) -> URL {
        URL(fileURLWithPath: "/Comics").appendingPathComponent(name)
    }

    @Test func unrelatedWorksInTheSameFolderAreNotASeries() {
        // The case that prompted the matcher: two different works side by side.
        let book = url("세평유")
        let siblings = [book, url("강철의 연금술사 풀컬러 웹툰 1-294 완결")]
        #expect(SeriesVolumeMatcher.volumes(matching: book, among: siblings).isEmpty)
    }

    @Test func numberedVolumesOfOneTitleAreASeries() {
        let book = url("세평유 1화.cbz")
        let siblings = [book, url("세평유 2화.cbz"), url("세평유 10화.cbz"), url("다른 만화 1권.cbz")]
        #expect(SeriesVolumeMatcher.volumes(matching: book, among: siblings).map(\.lastPathComponent)
            == ["세평유 2화.cbz", "세평유 10화.cbz"])
    }

    @Test func volumeMarkersAndReleaseTagsAreIgnored() {
        #expect(SeriesVolumeMatcher.titleStem("One Piece v01.cbz") == SeriesVolumeMatcher.titleStem("One Piece v02 (Digital).cbz"))
        #expect(SeriesVolumeMatcher.titleStem("[Group] Berserk Vol. 3.zip") == SeriesVolumeMatcher.titleStem("Berserk Vol.41.zip"))
        #expect(SeriesVolumeMatcher.titleStem("ワンピース 第1巻.cbz") == SeriesVolumeMatcher.titleStem("ワンピース 第2巻.cbz"))
        #expect(SeriesVolumeMatcher.titleStem("Berserk v01.cbz") != SeriesVolumeMatcher.titleStem("Vagabond v01.cbz"))
    }

    @Test func purelyNumberedBooksFormASeries() {
        let book = url("01.cbz")
        let siblings = [book, url("02.cbz"), url("03")]
        #expect(SeriesVolumeMatcher.volumes(matching: book, among: siblings).count == 2)
    }
}
