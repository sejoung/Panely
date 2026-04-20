import Testing
@testable import Panely

struct ReadingDirectionTests {
    @Test func leftToRightIsNotRTL() {
        #expect(ReadingDirection.leftToRight.isRTL == false)
    }

    @Test func rightToLeftIsRTL() {
        #expect(ReadingDirection.rightToLeft.isRTL == true)
    }

    @Test func rawValuesRoundTrip() {
        for direction in ReadingDirection.allCases {
            let restored = ReadingDirection(rawValue: direction.rawValue)
            #expect(restored == direction)
        }
    }
}

struct PageLayoutTests {
    @Test func rawValuesAreStable() {
        #expect(PageLayout.single.rawValue == "single")
        #expect(PageLayout.double.rawValue == "double")
        #expect(PageLayout.vertical.rawValue == "vertical")
    }
}

struct FitModeTests {
    @Test func rawValuesAreStable() {
        #expect(FitMode.fitScreen.rawValue == "fitScreen")
        #expect(FitMode.fitWidth.rawValue == "fitWidth")
    }
}
