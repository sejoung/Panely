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

    @Test func cycleVisitsAllThreeModesInOrder() {
        #expect(PageLayout.single.next == .double)
        #expect(PageLayout.double.next == .vertical)
        #expect(PageLayout.vertical.next == .single)
    }

    @Test func navigationStepIsOneForPagedSingleAndVertical() {
        // Vertical loads everything as one strip — stepping is per image.
        #expect(PageLayout.single.navigationStep == 1)
        #expect(PageLayout.vertical.navigationStep == 1)
    }

    @Test func navigationStepIsTwoForDouble() {
        #expect(PageLayout.double.navigationStep == 2)
    }

    @Test func verticalIsFlaggedAsContinuous() {
        // A continuous layout means the viewer renders all pages at once
        // instead of paging through them in groups.
        #expect(PageLayout.vertical.isContinuous == true)
        #expect(PageLayout.single.isContinuous == false)
        #expect(PageLayout.double.isContinuous == false)
    }
}

struct FitModeTests {
    @Test func rawValuesAreStable() {
        #expect(FitMode.fitScreen.rawValue == "fitScreen")
        #expect(FitMode.fitWidth.rawValue == "fitWidth")
        #expect(FitMode.fitHeight.rawValue == "fitHeight")
    }

    @Test func cycleVisitsAllThreeModesInOrder() {
        #expect(FitMode.fitScreen.next == .fitWidth)
        #expect(FitMode.fitWidth.next == .fitHeight)
        #expect(FitMode.fitHeight.next == .fitScreen)
    }
}
