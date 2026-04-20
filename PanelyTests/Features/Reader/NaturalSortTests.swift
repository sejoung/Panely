import Testing
import Foundation
@testable import Panely

struct NaturalSortTests {
    @Test func numericSegmentsSortNumerically() {
        let names = ["10.cbz", "2.cbz", "1.cbz", "20.cbz"]
        let sorted = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #expect(sorted == ["1.cbz", "2.cbz", "10.cbz", "20.cbz"])
    }

    @Test func mixedPrefixSortedLexicallyAcrossPrefix() {
        let names = ["Vol 10.cbz", "Vol 2.cbz", "Vol 1.cbz"]
        let sorted = names.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        #expect(sorted == ["Vol 1.cbz", "Vol 2.cbz", "Vol 10.cbz"])
    }
}
