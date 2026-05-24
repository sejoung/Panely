import Foundation
import Testing
@testable import Panely

struct DiagnosticLogStoreTests {
    @Test func testRunsUseSeparateDiagnosticLogDirectory() async {
        let url = await DiagnosticLogStore.shared.logFileURL()

        #expect(url.path.contains("panely-diagnostics-tests"))
        #expect(url.path.contains("panely-diagnostics/recent-log.txt") == false)
    }
}
