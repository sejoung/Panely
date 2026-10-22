import Foundation
import Testing

struct EntitlementsTests {
    @Test func sandboxAllowsUserSelectedSavePanelDestinations() throws {
        let entitlements = try loadEntitlements()

        #expect(entitlements["com.apple.security.app-sandbox"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.user-selected.read-write"] as? Bool == true)
        #expect(entitlements["com.apple.security.files.user-selected.read-only"] == nil)
    }

    /// The translation model is downloaded from the app (Hugging Face).
    /// Outgoing connections only — Panely serves nothing.
    @Test func sandboxAllowsDownloadingTheTranslationModel() throws {
        let entitlements = try loadEntitlements()

        #expect(entitlements["com.apple.security.network.client"] as? Bool == true)
        #expect(entitlements["com.apple.security.network.server"] == nil)
    }

    private func loadEntitlements() throws -> [String: Any] {
        let testFile = URL(fileURLWithPath: #filePath)
        let root = testFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let url = root.appendingPathComponent("Panely.entitlements")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return try #require(plist as? [String: Any])
    }
}
