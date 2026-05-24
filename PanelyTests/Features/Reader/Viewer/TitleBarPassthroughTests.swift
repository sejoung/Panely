import Testing
@testable import Panely

struct TitleBarPassthroughTests {
    @Test func doubleClickActionDefaultsToZoom() {
        #expect(WindowDoubleClickAction(rawSystemValue: nil) == .zoom)
        #expect(WindowDoubleClickAction(rawSystemValue: "Maximize") == .zoom)
    }

    @Test func doubleClickActionMapsSystemValues() {
        #expect(WindowDoubleClickAction(rawSystemValue: "Minimize") == .minimize)
        #expect(WindowDoubleClickAction(rawSystemValue: "None") == .none)
    }
}
