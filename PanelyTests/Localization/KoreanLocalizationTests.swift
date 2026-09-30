import Testing
import Foundation
@testable import Panely

/// The Korean translations ship in a string catalog whose keys have to match
/// what the code generates — including the format specifiers interpolation
/// produces. A mismatch isn't a build error; the string just silently stays
/// English. These resolve a sample through the built `ko.lproj` to catch that.
@MainActor
struct KoreanLocalizationTests {

    @Test func appShipsKoreanLocalization() {
        #expect(Bundle.main.localizations.contains("ko"))
    }

    @Test func plainKeysResolveToKorean() throws {
        let ko = try koreanBundle()
        #expect(String(localized: "Double Page (⌘⇧2)", bundle: ko) == "두 장 보기 (⌘⇧2)")
        #expect(String(localized: "Zoom In (⌘+)", bundle: ko) == "확대 (⌘+)")
        #expect(String(localized: "Next Volume (])", bundle: ko) == "다음 권 · 다음 압축파일 (])")
        #expect(String(localized: "Bookmarks", bundle: ko) == "북마크")
        #expect(String(localized: "System Default", bundle: ko) == "시스템 설정 따르기")
    }

    @Test func interpolatedKeysResolveToKorean() throws {
        let ko = try koreanBundle()
        let page = 12
        #expect(String(localized: "Page \(page)", bundle: ko) == "12페이지")
        #expect(String(localized: "Vol \(2) / \(5)", bundle: ko) == "2 / 5권")
        #expect(String(localized: "\(40)% read", bundle: ko) == "40% 읽음")
        let arrow = "→"
        #expect(String(localized: "Next Page (\(arrow) or Space)", bundle: ko) == "다음 페이지 (→ 또는 Space)")
        let megabytes = 512
        #expect(
            String(localized: "Archive expanded past the safety limit (\(megabytes) MB).", bundle: ko)
                == "압축을 푼 크기가 안전 한도(512MB)를 넘었습니다."
        )
        let entry = "001.jpg"
        #expect(
            String(localized: "The archive has no entry named \"\(entry)\".", bundle: ko)
                == "압축파일에 “001.jpg” 항목이 없습니다."
        )
        let title = "Series"
        #expect(String(localized: "Remove all bookmarks in “\(title)”?", bundle: ko) == "“Series”의 북마크를 모두 삭제할까요?")
    }

    @Test func userFacingNoticesAreTranslated() throws {
        let ko = try koreanBundle()
        // Every notice must differ from its English source — i.e. be in the catalog.
        let english = [
            "This is the last book in the folder.",
            "This is the first book in the folder.",
            "Panely can only see this one book. Allow access to its folder to move between the books in it.",
            "This bookmarked book can no longer be opened.",
        ]
        for key in english {
            #expect(ko.localizedString(forKey: key, value: nil, table: nil) != key)
        }
    }

    private func koreanBundle() throws -> Bundle {
        let url = try #require(Bundle.main.url(forResource: "ko", withExtension: "lproj"))
        return try #require(Bundle(url: url))
    }
}
